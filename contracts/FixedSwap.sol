// SPDX-License-Identifier: Waggle

pragma solidity ^0.8.0;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

interface IFarm {
	function userInfo(uint256 _poolId, address _address)
		external
		view
		returns (
			uint256,
			uint256,
			uint256
		);
}

contract Whitelist is Ownable {
	mapping(address => bool) public whitelist;
	bool public hasWhitelisting = false;

	modifier onlyWhitelisted() {
		if (hasWhitelisting) {
			require(isWhitelisted(msg.sender));
		}
		_;
	}

	constructor(bool _hasWhitelisting) {
		hasWhitelisting = _hasWhitelisting;
	}

	function add(address[] memory _addresses) public onlyOwner {
		for (uint256 i = 0; i < _addresses.length; i++) {
			address a = _addresses[i];
			if (!whitelist[a]) {
				whitelist[a] = true;
			}
		}
	}

	function remove(address _address) public onlyOwner {
		require(whitelist[_address], "Not whitelisted");
		whitelist[_address] = false;
	}

	function isWhitelisted(address _address) public view returns (bool) {
		return whitelist[_address];
	}
}

contract FixedSwap is Pausable, Whitelist {
	using SafeMath for uint256;
	uint256 constant FULL_100 = 100000000000000000000;

	IFarm farmContract;

	address seller;
	address[] public buyers;
	mapping(address => uint256) public boughtAmounts;
	mapping(address => uint256) public redeemedAmounts;
	mapping(address => mapping(uint256 => bool)) public redeemFinalizeds; /* Adress -> RedeemId -> True/False */

	RedeemConfig[] public redeemConfigs;
	struct RedeemConfig {
		uint256 id;
		uint256 date;
		uint256 percentage;
	}

	AmountConfig[] public individualAmounts;
	struct AmountConfig {
		uint256 amount;
		uint256 lpAmount;
	}

	ERC20 public erc20;
	ERC20 public tradeErc20;
	uint256 public tradeValue;
	uint256 public startDate;
	uint256 public endDate;
	uint256 public tokensAllocated = 0;
	uint256 public tokensForSale = 0;
	uint256 public tokensFund = 0;
	bool public isTokenSwapAtomic;
	bool public fundWithdrawed;
	bool public unsoldTokensReedemed;

	uint256 public tax = 5; // 5%

	event PurchaseEvent(uint256 amount, address indexed purchaser, uint256 timestamp);

	constructor(
		address _tokenAddress,
		address _tradeTokenAddress,
		uint256 _tradeValue,
		uint256 _tokensForSale,
		uint256[] memory _dateConfigs,
		bool _isTokenSwapAtomic,
		bool _hasWhitelisting,
		address _farmAddress,
		address _seller
	) Whitelist(_hasWhitelisting) {
		uint256 _startDate = _dateConfigs[0];
		uint256 _endDate = _dateConfigs[1];
		require(_startDate < _endDate, "End Date gte Start Date");
		require(_tokensForSale > 0, "Tokens for Sale eq 0");

		startDate = _startDate;
		endDate = _endDate;
		tokensForSale = _tokensForSale;
		tradeValue = _tradeValue;
		isTokenSwapAtomic = _isTokenSwapAtomic;

		erc20 = ERC20(_tokenAddress);
		if (_tradeTokenAddress != address(0)) {
			tradeErc20 = ERC20(_tradeTokenAddress);
		}
		farmContract = IFarm(_farmAddress);
		seller = _seller;
	}

	modifier financeAdmin() {
		require(owner() == _msgSender() || seller == _msgSender(), "Permission denied");
		_;
	}

	modifier isNotAtomicSwap() {
		require(!isTokenSwapAtomic, "Has to be non Atomic swap");
		_;
	}

	modifier isSaleFinalized() {
		require(hasFinalized(), "Has to be finalized");
		_;
	}

	modifier isSaleOpen() {
		require(isOpen(), "Has to be open");
		_;
	}

	modifier isValidPurchaseId(uint256 _purchaseId) {
		require(_purchaseId < redeemConfigs.length, "Not valid PurchaseId");
		_;
	}

	function isBuyer(address _address) public view returns (bool) {
		return boughtAmounts[_address] > 0;
	}

	function totalRaiseCost() public view returns (uint256) {
		return cost(tokensForSale);
	}

	function getIndividualMaximumAmount() public view returns (uint256) {
		return getIndividualMaximumAmountOfAccount(msg.sender);
	}

	function getIndividualMaximumAmountOfAccount(address account) public view returns (uint256) {
		if (individualAmounts.length > 0) {
			uint256 lpAmount = 0;
			(lpAmount, , ) = farmContract.userInfo(0, account);
			for (uint256 i = individualAmounts.length; i > 0; i--) {
				AmountConfig memory config = individualAmounts[i - 1];
				if (lpAmount >= config.lpAmount) {
					return config.amount;
				}
			}
		}
		return 0;
	}

	function tokensLeft() public view returns (uint256) {
		return tokensForSale - tokensAllocated;
	}

	function hasFinalized() public view returns (bool) {
		return block.timestamp > endDate;
	}

	function hasStarted() public view returns (bool) {
		return block.timestamp >= startDate;
	}

	function isOpen() public view returns (bool) {
		return hasStarted() && !hasFinalized();
	}

	function cost(uint256 _amount) public view returns (uint256) {
		uint256 erc20Decimals = erc20.decimals();
		uint256 tradeErc20Decimals = address(tradeErc20) != address(0) ? tradeErc20.decimals() : 18;
		return _amount.mul(tradeValue).div(10**(18 - tradeErc20Decimals)).div(10**erc20Decimals);
	}

	function getPurchase(address _address, uint256 _purchase_id)
		external
		view
		returns (
			uint256,
			address,
			uint256,
			uint256,
			bool,
			uint256
		)
	{
		RedeemConfig memory config = redeemConfigs[_purchase_id];
		uint256 amount = boughtAmounts[_address].mul(config.percentage).div(FULL_100);
		return (
			amount,
			_address,
			cost(amount),
			config.date,
			redeemFinalizeds[_address][_purchase_id],
			config.percentage
		);
	}

	function getPendingPurchase(address _address)
		external
		view
		returns (
			uint256,
			address,
			uint256
		)
	{
		uint256 totalPercent = 0;
		for (uint256 i = 0; i < redeemConfigs.length; i++) {
			totalPercent = totalPercent.add(redeemConfigs[i].percentage);
		}
		uint256 amount = boughtAmounts[_address].mul(FULL_100.sub(totalPercent)).div(FULL_100);
		return (amount, _address, cost(amount));
	}

	function getBoughtAmount(address _address) external view returns (uint256) {
		return boughtAmounts[_address];
	}

	function getRedeemedAmount(address _address) external view returns (uint256) {
		return redeemedAmounts[_address];
	}

	function getPendingAmount(address _address) external view returns (uint256) {
		return boughtAmounts[_address].sub(redeemedAmounts[_address]);
	}

	function getBuyers() external view returns (address[] memory) {
		return buyers;
	}

	function getBuyerLength() external view returns (uint256) {
		return buyers.length;
	}

	function getMyPurchases(address _address) external view returns (uint256[] memory) {
		if (isBuyer(_address)) {
			uint256[] memory results = new uint256[](redeemConfigs.length);
			for (uint256 i = 0; i < redeemConfigs.length; i++) {
				results[i] = i;
			}
			return results;
		} else {
			return new uint256[](0);
		}
	}

	function fund(address _tokenAddress, uint256 _amount) public {
		require(address(erc20) == _tokenAddress, "Invalid token");
		require(tokensFund.add(_amount) <= tokensForSale, "Over tokenForSale");
		erc20.transferFrom(msg.sender, address(this), _amount);
		tokensFund = tokensFund.add(_amount);
	}

	function buy(uint256 _amount) external payable whenNotPaused isSaleOpen onlyWhitelisted {
		require(_amount > 0, "Amount lte 0");
		require(_amount <= tokensLeft(), "Amount gt tokens available");
		require(boughtAmounts[msg.sender].add(_amount) <= getIndividualMaximumAmount(), "Over max amount");

		uint256 costValue = cost(_amount);
		if (address(tradeErc20) != address(0)) {
			require(tradeErc20.transferFrom(msg.sender, address(this), costValue), "ERC20 transfer failed");
			require(msg.value == 0, "BNB value is not valid");
		} else {
			require(msg.value == costValue, "BNB value is not valid");
		}

		if (isTokenSwapAtomic) {
			uint256 amountTax = _amount.mul(tax).div(100);
			require(erc20.transfer(msg.sender, _amount.sub(amountTax)), "ERC20 transfer failed");
			require(erc20.transfer(owner(), amountTax), "ERC20 transfer failed");
		}

		if (!isBuyer(msg.sender)) {
			buyers.push(msg.sender);
		}
		boughtAmounts[msg.sender] = boughtAmounts[msg.sender].add(_amount);
		tokensAllocated = tokensAllocated.add(_amount);

		emit PurchaseEvent(_amount, msg.sender, block.timestamp);
	}

	function redeemTokens(uint256 purchase_id)
		external
		isNotAtomicSwap
		isSaleFinalized
		whenNotPaused
		isValidPurchaseId(purchase_id)
	{
		require(isBuyer(msg.sender), "Address is not buyer");
		require(!redeemFinalizeds[msg.sender][purchase_id], "Purchase is finalized");

		RedeemConfig memory config = redeemConfigs[purchase_id];
		require(block.timestamp > config.date, "This purchase is not valid now");

		// uint256 maximum = getIndividualMaximumAmountOfAccount(msg.sender);
		// require(maximum >= boughtAmounts[msg.sender], "Holder or Farmer only");

		uint256 amount = boughtAmounts[msg.sender].mul(config.percentage).div(FULL_100);
		uint256 remainedAmount = boughtAmounts[msg.sender].sub(redeemedAmounts[msg.sender]);
		if (amount > remainedAmount) {
			amount = remainedAmount;
		}
		redeemedAmounts[msg.sender] = redeemedAmounts[msg.sender].add(amount);
		redeemFinalizeds[msg.sender][purchase_id] = true;

		uint256 amountTax = amount.mul(tax).div(100);
		require(erc20.transfer(owner(), amountTax), "ERC20 transfer failed");
		require(erc20.transfer(msg.sender, amount.sub(amountTax)), "ERC20 transfer failed");
	}

	function getRedeemConfigLength() public view returns (uint256) {
		return redeemConfigs.length;
	}

	function getRedeemConfigAt(uint256 index) public view returns (uint256, uint256) {
		RedeemConfig memory config = redeemConfigs[index];
		return (config.date, config.percentage);
	}

	function getAmountConfigLength() public view returns (uint256) {
		return individualAmounts.length;
	}

	function getAmountConfigAt(uint256 index) public view returns (uint256, uint256) {
		AmountConfig memory config = individualAmounts[index];
		return (config.amount, config.lpAmount);
	}

	/* Admin Functions */
	function setRedeemConfigs(RedeemConfig[] calldata _redeemConfigs) external onlyOwner {
		for (uint256 i = 0; i < _redeemConfigs.length; i++) {
			RedeemConfig memory newConfig = _redeemConfigs[i];
			if (newConfig.id < redeemConfigs.length) {
				// update
				redeemConfigs[newConfig.id].percentage = newConfig.percentage;
				redeemConfigs[newConfig.id].date = newConfig.date;
			} else {
				require(newConfig.id == redeemConfigs.length, "Invalid id");
				// add new
				redeemConfigs.push(newConfig);
			}
		}
		uint256 totalPercent = 0;
		for (uint256 i = 0; i < redeemConfigs.length; i++) {
			totalPercent = totalPercent.add(redeemConfigs[i].percentage);
		}
		require(totalPercent <= FULL_100, "Total gt 100%");
	}

	function setAmountConfigs(AmountConfig[] calldata _amountConfigs) external onlyOwner {
		for (uint256 i = 0; i < _amountConfigs.length; i++) {
			AmountConfig memory amountConfig = _amountConfigs[i];
			if (i < individualAmounts.length) {
				individualAmounts[i].amount = amountConfig.amount;
				individualAmounts[i].lpAmount = amountConfig.lpAmount;
			} else {
				individualAmounts.push(amountConfig);
			}
		}
	}

	function withdrawFunds() external financeAdmin isSaleFinalized {
		require(!fundWithdrawed, "Withdrawed");
		fundWithdrawed = true;
		if (address(tradeErc20) == address(0)) {
			uint256 fundTax = address(this).balance.mul(tax).div(100);
			uint256 fundAmount = address(this).balance.sub(fundTax);
			payable(owner()).transfer(fundTax);
			payable(msg.sender).transfer(fundAmount);
		} else {
			uint256 allocatedCost = cost(tokensAllocated);
			if (allocatedCost > tradeErc20.balanceOf(address(this)))
				allocatedCost = tradeErc20.balanceOf(address(this));
			uint256 fundTax = allocatedCost.mul(tax).div(100);
			uint256 fundAmount = allocatedCost.sub(fundTax);
			require(tradeErc20.transfer(owner(), fundTax), "ERC20 transfer failed");
			require(tradeErc20.transfer(msg.sender, fundAmount), "ERC20 transfer failed");
		}
	}

	function withdrawUnsoldTokens() external financeAdmin isSaleFinalized {
		require(!unsoldTokensReedemed, "Removed");
		unsoldTokensReedemed = true;
		uint256 unsoldTokens = tokensForSale.sub(tokensAllocated);
		require(erc20.transfer(msg.sender, unsoldTokens), "ERC20 transfer failed");
	}

	function removeOtherERC20Tokens(address _tokenAddress, address _to) external onlyOwner {
		ERC20 erc20Token = ERC20(_tokenAddress);
		erc20Token.transfer(_to, erc20Token.balanceOf(address(this)));
	}

	function changeErcToken(address _token) external onlyOwner {
		erc20 = ERC20(_token);
	}

	function changeStartDate(uint256 _startDate) external onlyOwner {
		startDate = _startDate;
	}

	function changeEndDate(uint256 _endDate) external onlyOwner {
		endDate = _endDate;
	}

	function pause() public financeAdmin whenNotPaused {
		_pause();
	}

	function unpause() public financeAdmin whenPaused {
		_unpause();
	}
}
