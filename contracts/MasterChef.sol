// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/utils/Pausable.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import './interface/IFairy.sol';

contract MasterChef is Ownable, Pausable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. FAIRYs to distribute per block.
        uint256 lastRewardTime;  // Last second that reward distribution occurs.
        uint256 accFairyPerShare; // Accumulated FAIRYs per share, times 1e12. See below.
    }

    // Info about token emissions for a given time period.
    struct EmissionPoint {
        uint128 startTimeOffset;
        uint256 rewardsPerSum;
        uint256 rewardsDays;
    }
    
    address public fairy;
    // The block number when reward mining starts.
    uint256 public startTime;
    // FAIRY tokens created per second.
    uint256 public rewardsPerSecond;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;

    // Data about the future reward rates. emissionSchedule stored in reverse chronological order,
    // whenever the number of blocks since the start block exceeds the next block offset a new
    // reward rate is applied.
    EmissionPoint[] public emissionSchedule;
    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;

    event AddPool(address indexed user, uint256 allocPoint, address lpToken, bool _withUpdate);
    event SetPool(address indexed user, uint256 indexed pid, uint256 allocPoint, bool _withUpdate);
    event Schedule(address indexed user, uint128[] startTimeOffset, uint256[] totalRewards, uint256[] rewardsDays);
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    modifier validatePoolByPid(uint256 _pid) {
        require (_pid < poolInfo.length , "Pool does not exist") ; 
        _;
    }

    constructor(
        address _fairy,
        uint256 _startTime
    ) public {
        fairy = _fairy;
        startTime = _startTime;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(uint256 _allocPoint, IERC20 _lpToken, bool _withUpdate) external onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardTime = block.timestamp > startTime ? block.timestamp : startTime;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardTime: lastRewardTime,
            accFairyPerShare: 0
        }));
        emit AddPool(msg.sender, _allocPoint, address(_lpToken), _withUpdate);
    }

    function getPoolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Update the given pool's FAIRY allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) external onlyOwner validatePoolByPid(_pid) {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 prevAllocPoint = poolInfo[_pid].allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
        if (prevAllocPoint != _allocPoint) {
            totalAllocPoint = totalAllocPoint.sub(prevAllocPoint).add(_allocPoint);
        }
        emit SetPool(msg.sender, _pid, _allocPoint, _withUpdate);
    }

    function setSchedule(
        uint128[] calldata _startTimeOffset, 
        uint256[] calldata _rewardsPerSum,
        uint256[] calldata _rewardsDays
    ) external onlyOwner{
        require (_startTimeOffset.length == _rewardsPerSum.length, 'parameter error');
        for (uint256 i = _startTimeOffset.length - 1; i + 1 != 0; i--) {
            emissionSchedule.push(
                EmissionPoint({
                    startTimeOffset: _startTimeOffset[i],
                    rewardsPerSum: _rewardsPerSum[i],
                    rewardsDays: _rewardsDays[i]
                })
            );
        }
        emit Schedule(msg.sender, _startTimeOffset, _totalRewards, _rewardsDays);
    }

    function _examineEmission() internal {
        uint256 length = emissionSchedule.length;
        if (startTime > 0 && length > 0) {
            EmissionPoint memory e = emissionSchedule[length-1];
            if (block.timestamp.sub(startTime) > e.startTimeOffset) {
                uint256 daysToSecond = e.rewardsDays.mul(60).mul(60).mul(24);
                rewardsPerSecond = e.rewardsPerSum.mul(1e12).div(daysToSecond).div(1e12);
                emissionSchedule.pop();
            }
        }
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 poolLength = poolInfo.length;
        for (uint256 pid = 0; pid < poolLength; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public validatePoolByPid(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }
        uint256 multiplier = _getMultiplier(pool.lastRewardTime, block.timestamp);
        uint256 fairyReward = multiplier.mul(rewardsPerSecond).mul(pool.allocPoint).div(totalAllocPoint);
        pool.accFairyPerShare = pool.accFairyPerShare.add(fairyReward.mul(1e12).div(lpSupply));
        pool.lastRewardTime = block.timestamp;
        // examine emission schedule
        _examineEmission();
    }

    // Return reward multiplier over the given _from to _to block.
    function _getMultiplier(uint256 _from, uint256 _to) internal pure returns (uint256) {
        return _to.sub(_from);
    }

    // View function to see pending FAIRYs on frontend.
    function pendingFairy(uint256 _pid, address _user) external view  validatePoolByPid(_pid) returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accFairyPerShare = pool.accFairyPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.timestamp > pool.lastRewardTime && lpSupply != 0) {
            uint256 multiplier = _getMultiplier(pool.lastRewardTime, block.timestamp);
            uint256 fairyReward = multiplier.mul(rewardsPerSecond).mul(pool.allocPoint).div(totalAllocPoint);
            accFairyPerShare = accFairyPerShare.add(fairyReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accFairyPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Deposit LP tokens to MasterChef for FAIRY allocation.
    function deposit(uint256 _pid, uint256 _amount) external whenNotPaused nonReentrant validatePoolByPid(_pid) {
        require (block.timestamp >= startTime, 'not yet started');
        // require (_pid != 0, 'deposit FAIRY by staking');

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accFairyPerShare).div(1e12).sub(user.rewardDebt);
            if(pending > 0) {
                _fairyMint(msg.sender, pending);
            }
        }
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accFairyPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) external nonReentrant validatePoolByPid(_pid) {

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");

        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accFairyPerShare).div(1e12).sub(user.rewardDebt);
        if(pending > 0) {
            _fairyMint(msg.sender, pending);
        }
        if(_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accFairyPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) external nonReentrant validatePoolByPid(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        pool.lpToken.safeTransfer(address(msg.sender), user.amount);
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
    }

    // Claim pending rewards for one or more pools.
    // Rewards are not received directly, they are minted by the FAIRY.
    function claim(uint256[] calldata _pids) external nonReentrant {
        massUpdatePools();
        uint256 pending;
        for (uint i = 0; i < _pids.length; i++) {
            PoolInfo storage pool = poolInfo[_pids[i]];
            UserInfo storage user = userInfo[_pids[i]][msg.sender];
            pending = pending.add(user.amount.mul(pool.accFairyPerShare).div(1e12).sub(user.rewardDebt));
            user.rewardDebt = user.amount.mul(pool.accFairyPerShare).div(1e12);
        }
        if (pending > 0) {
            _fairyMint(msg.sender, pending);
        }
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