// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/utils/Pausable.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import './interface/IFairy.sol';

contract SmartChef is Ownable, Pausable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // The reward token
    address public fairy;

    // The staked token
    IERC20 public stakedToken;

    // FAIRY tokens created per second.
    uint256 public rewardsPerSecond;

    // Accrued token per share
    uint256 public accTokenPerShare;

    // The time when FAIRY mining ends.
    uint256 public endTime;

    // The time when FAIRY mining starts.
    uint256 public startTime;

    // The time of the last pool update
    uint256 public lastRewardTime;

    // Info of each user that stakes tokens (stakedToken)
    mapping(address => UserInfo) public userInfo;

    struct UserInfo {
        uint256 amount; // How many staked tokens the user has provided
        uint256 rewardDebt; // Reward debt
    }

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 amount);

    constructor(
        address _fairy,
        IERC20 _stakedToken,
        uint256 _totalRewards,
        uint256 _rewardsDays,
        uint256 _startTime
    ) public {
        fairy = _fairy;
        stakedToken = _stakedToken;
        startTime = _startTime;

        // calculate rewardsPerSecond
        uint256 daysToSecond = _rewardsDays.mul(60).mul(60).mul(24);
        rewardsPerSecond = _totalRewards.mul(1e12).div(daysToSecond).div(1e12);

        endTime = startTime.add(daysToSecond);

        // Set the lastRewardTime as the startTime
        lastRewardTime = startTime;
    }

    /*
     * @notice Return reward multiplier over the given _from to _to time.
     * @param _from: time to start
     * @param _to: time to finish
     */
    function _getMultiplier(uint256 _from, uint256 _to) internal view returns (uint256) {
        if (_to <= endTime) {
            return _to.sub(_from);
        } else if (_from >= endTime) {
            return 0;
        } else {
            return endTime.sub(_from);
        }
    }

    /*
     * @notice Update reward variables of the given pool to be up-to-date.
     */
    function _updatePool() internal {
        if(block.timestamp >= endTime){
            return;
        }
        if (block.timestamp <= lastRewardTime) {
            return;
        }
        uint256 stakedTokenSupply = stakedToken.balanceOf(address(this));
        if (stakedTokenSupply == 0) {
            lastRewardTime = block.timestamp;
            return;
        }
        uint256 multiplier = _getMultiplier(lastRewardTime, block.timestamp);
        uint256 fairyReward = multiplier.mul(rewardsPerSecond);
        accTokenPerShare = accTokenPerShare.add(fairyReward.mul(1e12).div(stakedTokenSupply));
        lastRewardTime = block.timestamp;
    }

    /*
     * @notice Deposit staked tokens and collect reward tokens (if any)
     * @param _amount: amount to withdraw (in rewardToken)
     */
    function deposit(uint256 _amount) external nonReentrant {
        require(block.timestamp >= startTime, "SmartChef: not start");
        require(block.timestamp < endTime, "SmartChef: is end");
        UserInfo storage user = userInfo[msg.sender];
        _updatePool();
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(accTokenPerShare).div(1e12).sub(user.rewardDebt);
            if (pending > 0) {
                _fairyMint(address(msg.sender), pending);
            }
        }
        if (_amount > 0) {
            user.amount = user.amount.add(_amount);
            stakedToken.safeTransferFrom(address(msg.sender), address(this), _amount);
        }
        user.rewardDebt = user.amount.mul(accTokenPerShare).div(1e12);
        emit Deposit(msg.sender, _amount);
    }

    /*
     * @notice Withdraw staked tokens and collect reward tokens
     * @param _amount: amount to withdraw (in rewardToken)
     */
    function withdraw(uint256 _amount) external nonReentrant {
        UserInfo storage user = userInfo[msg.sender];
        require(user.amount >= _amount, "Amount to withdraw too high");
        _updatePool();
        uint256 pending = user.amount.mul(accTokenPerShare).div(1e12).sub(user.rewardDebt);
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            stakedToken.safeTransfer(address(msg.sender), _amount);
        }
        if (pending > 0) {
            _fairyMint(address(msg.sender), pending);
        }
        user.rewardDebt = user.amount.mul(accTokenPerShare).div(1e12);
        emit Withdraw(msg.sender, _amount);
    }

    /*
     * @notice Withdraw staked tokens without caring about rewards rewards
     * @dev Needs to be for emergency.
     */
    function emergencyWithdraw() external nonReentrant {
        UserInfo storage user = userInfo[msg.sender];
        uint256 amountToTransfer = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        if (amountToTransfer > 0) {
            stakedToken.safeTransfer(address(msg.sender), amountToTransfer);
        }
        emit EmergencyWithdraw(msg.sender, user.amount);
    }

    /*
     * @notice View function to see pending reward on frontend.
     * @param _user: user address
     * @return Pending reward for a given user
     */
    function pendingFairy(address _user) external view returns (uint256) {
        UserInfo memory user = userInfo[_user];
        uint256 adjustedTokenPerShare = accTokenPerShare;
        uint256 stakedTokenSupply = stakedToken.balanceOf(address(this));
        if (block.timestamp > lastRewardTime && stakedTokenSupply != 0) {
            uint256 multiplier = _getMultiplier(lastRewardTime, block.timestamp);
            uint256 fairyReward = multiplier.mul(rewardsPerSecond);
            adjustedTokenPerShare =
                accTokenPerShare.add(fairyReward.mul(1e12).div(stakedTokenSupply));   
        }
        return user.amount.mul(adjustedTokenPerShare).div(1e12).sub(user.rewardDebt);
    }

    // fairy mint function, just in case if rounding error causes pool to not have enough FAIRYs.
    function _fairyMint(address _to, uint256 _amount) internal {
        IFairy(fairy).mint(_to, _amount);
    }

    // 设置总开关
    function pause() external onlyOwner returns (bool) {
        _pause();
        return true;
    }
    function unpause() external onlyOwner returns (bool) {
        _unpause();
        return true;
    }
}