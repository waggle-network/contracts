// SPDX-License-Identifier: WAGGLE
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

contract MyFarm is Ownable {
	using SafeMath for uint256;
	using SafeERC20 for IERC20;

	struct UserInfo {
		uint256 amount; // How many LP tokens the user has provided.
		uint256 rewardDebt; // Ignore this reward
		uint256 rewardAmount;
		uint256 lastStakeTime;
	}

	// Info of each pool.
	struct PoolInfo {
		IERC20 lpToken; // Address of LP token contract.
		uint256 allocPoint; // How many allocation points assigned to this pool. IMMs to distribute per block.
		uint256 lastRewardBlock; // Last block number that IMMs distribution occurs.
		uint256 accRewardPerShare; // Accumulated IMMs per share, times 1e12. See below.
	}

	// The IMM TOKEN!
	ERC20 public rewardToken;
	// IMM tokens created per block.
	uint256 public tokenPerBlock;
	// Check what LP added.
	mapping(address => bool) public addedLPs;
	// Bonus muliplier for early imm makers.
	uint256 public BONUS_MULTIPLIER = 1;

	// Info of each pool.
	PoolInfo[] public poolInfo;
	// Info of each user that stakes LP tokens.
	mapping(uint256 => mapping(address => UserInfo)) public userInfo;
	// Total allocation points. Must be the sum of all allocation points in all pools.
	uint256 public totalAllocPoint = 0;
	// The block number when IMM mining starts.
	uint256 public startBlock;
	// Time for lock LP token from last stake
	uint256 public lockLPTokenTime = 0;

	event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
	event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
	event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
	event Harvest(address indexed user, uint256 indexed pid, uint256 amount);

	constructor(
		address _rewardTokenAddress,
		uint256 _rewardPerBlock,
		uint256 _startBlock
	) {
		rewardToken = ERC20(_rewardTokenAddress);
		tokenPerBlock = _rewardPerBlock;
		startBlock = _startBlock;
	}

	modifier verifyPoolId(uint256 _pid) {
		require(_pid < poolInfo.length, "Pool is not exist");
		_;
	}

	function poolLength() external view returns (uint256) {
		return poolInfo.length;
	}

	// Return reward multiplier over the given _from to _to block.
	function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
		return _to.sub(_from).mul(BONUS_MULTIPLIER);
	}

	function getUserInfo(uint256 _pid, address _user) public view returns (uint256, uint256) {
		UserInfo memory user = userInfo[_pid][_user];
		return (user.amount, user.lastStakeTime);
	}

	function getUserStakeBalance(uint256 _pid, address _user) external view returns (uint256) {
		return userInfo[_pid][_user].amount;
	}

	// View function to see pending IMMs on frontend.
	function getRewardAmount(uint256 _pid, address _user) external view verifyPoolId(_pid) returns (uint256) {
		PoolInfo memory pool = poolInfo[_pid];
		UserInfo memory user = userInfo[_pid][_user];
		uint256 accRewardPerShare = pool.accRewardPerShare;
		uint256 lpSupply = pool.lpToken.balanceOf(address(this));
		if (block.number > pool.lastRewardBlock && lpSupply != 0) {
			uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
			uint256 rewardAmount = multiplier.mul(tokenPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
			accRewardPerShare = accRewardPerShare.add(rewardAmount.mul(1e12).div(lpSupply));
		}

		uint256 pendingAmount = user.amount.mul(accRewardPerShare).div(1e12).sub(user.rewardDebt);
		return user.rewardAmount.add(pendingAmount);
	}

	// Update reward variables for all pools. Be careful of gas spending!
	function massUpdatePools() public {
		for (uint256 pid = 0; pid < poolInfo.length; ++pid) {
			updatePool(pid);
		}
	}

	// Update reward variables of the given pool to be up-to-date.
	function updatePool(uint256 _pid) public verifyPoolId(_pid) {
		PoolInfo storage pool = poolInfo[_pid];
		if (block.number <= pool.lastRewardBlock) {
			return;
		}
		uint256 lpSupply = pool.lpToken.balanceOf(address(this));
		if (lpSupply == 0) {
			pool.lastRewardBlock = block.number;
			return;
		}
		uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
		uint256 rewardAmount = multiplier.mul(tokenPerBlock).mul(pool.allocPoint).div(totalAllocPoint);

		pool.accRewardPerShare = pool.accRewardPerShare.add(rewardAmount.mul(1e12).div(lpSupply));
		pool.lastRewardBlock = block.number;
	}

	function stakeLP(uint256 _pid, uint256 _amount) external verifyPoolId(_pid) {
		require(_amount > 0, "amount must be greater than 0");
		updatePool(_pid);

		PoolInfo memory pool = poolInfo[_pid];
		UserInfo storage user = userInfo[_pid][msg.sender];

		// Update last reward
		uint256 pendingAmount = user.amount.mul(pool.accRewardPerShare).div(1e12).sub(user.rewardDebt);
		if (pendingAmount > 0) {
			user.rewardAmount = user.rewardAmount.add(pendingAmount);
		}

		// Add LP
		pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
		user.amount = user.amount.add(_amount);
		user.rewardDebt = user.amount.mul(pool.accRewardPerShare).div(1e12);
		user.lastStakeTime = block.timestamp;
		emit Deposit(msg.sender, _pid, _amount);
	}

	// Withdraw LP tokens from MasterChef.
	function unstakeLP(uint256 _pid, uint256 _amount) external verifyPoolId(_pid) {
		UserInfo storage user = userInfo[_pid][msg.sender];
		require(user.amount >= _amount && _amount > 0, "User is not in this farm or amount is not valid");
		require(user.lastStakeTime.add(lockLPTokenTime) < block.timestamp, "LPToken is locked now, please wait");

		updatePool(_pid);
		uint256 pendingAmount = user.amount.mul(poolInfo[_pid].accRewardPerShare).div(1e12).sub(user.rewardDebt);
		if (pendingAmount > 0) {
			user.rewardAmount = user.rewardAmount.add(pendingAmount);
		}
		PoolInfo memory pool = poolInfo[_pid];

		user.amount = user.amount.sub(_amount);
		pool.lpToken.safeTransfer(address(msg.sender), _amount);
		user.rewardDebt = user.amount.mul(pool.accRewardPerShare).div(1e12);
		emit Withdraw(msg.sender, _pid, _amount);
	}

	function harvest(uint256 _pid) external verifyPoolId(_pid) returns (uint256) {
		updatePool(_pid);

		PoolInfo memory pool = poolInfo[_pid];
		UserInfo storage user = userInfo[_pid][msg.sender];

		uint256 pendingAmount = user.amount.mul(pool.accRewardPerShare).div(1e12).sub(user.rewardDebt);
		pendingAmount = user.rewardAmount.add(pendingAmount);
		if (pendingAmount > 0) {
			rewardToken.transfer(msg.sender, pendingAmount);
		}
		user.rewardAmount = 0;
		user.rewardDebt = user.amount.mul(pool.accRewardPerShare).div(1e12);
		emit Harvest(msg.sender, _pid, pendingAmount);
		return pendingAmount;
	}

	// Withdraw without caring about rewards. EMERGENCY ONLY.
	function emergencyWithdraw(uint256 _pid) external verifyPoolId(_pid) {
		PoolInfo memory pool = poolInfo[_pid];
		UserInfo storage user = userInfo[_pid][msg.sender];
		pool.lpToken.safeTransfer(address(msg.sender), user.amount);
		emit EmergencyWithdraw(msg.sender, _pid, user.amount);
		user.amount = 0;
		user.rewardDebt = 0;
	}

	// ADMIN functions
	function updateMultiplier(uint256 multiplierNumber) external onlyOwner {
		BONUS_MULTIPLIER = multiplierNumber;
	}

	function setLockLPTokenTime(uint256 _lockTime) external onlyOwner {
		lockLPTokenTime = _lockTime;
	}

	function setTokenPerBlock(uint256 _tokenPerBlock) external onlyOwner {
		massUpdatePools();
		tokenPerBlock = _tokenPerBlock;
	}

	function add(
		uint256 _allocPoint,
		IERC20 _lpToken,
		bool _withUpdate
	) external onlyOwner {
		require(!addedLPs[address(_lpToken)], "LP Token is already added");
		if (_withUpdate) {
			massUpdatePools();
		}
		uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
		totalAllocPoint = totalAllocPoint.add(_allocPoint);
		poolInfo.push(
			PoolInfo({
				lpToken: _lpToken,
				allocPoint: _allocPoint,
				lastRewardBlock: lastRewardBlock,
				accRewardPerShare: 0
			})
		);
		addedLPs[address(_lpToken)] = true;
	}

	// Update the given pool's allocation point. Can only be called by the owner.
	function set(
		uint256 _pid,
		uint256 _allocPoint,
		bool _withUpdate
	) external onlyOwner verifyPoolId(_pid) {
		if (_withUpdate) {
			massUpdatePools();
		}
		if (poolInfo[_pid].allocPoint != _allocPoint) {
			totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
			poolInfo[_pid].allocPoint = _allocPoint;
		}
	}

	function removeBNB() external onlyOwner {
		(bool success, ) = payable(msg.sender).call{ value: address(this).balance }("");
		require(success, "Transfer failed");
	}

	function removeOtherToken(address _tokenAddress, address _to) external onlyOwner {
		ERC20 erc20Token = ERC20(_tokenAddress);
		require(erc20Token.transfer(_to, erc20Token.balanceOf(address(this))), "ERC20 Token transfer failed");
	}

	function removeOtherTokenWithAmount(
		address _tokenAddress,
		address _to,
		uint256 _amount
	) external onlyOwner {
		ERC20 erc20Token = ERC20(_tokenAddress);
		require(erc20Token.transfer(_to, _amount), "ERC20 Token transfer failed");
	}
}
