// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract Escrow is Ownable, ReentrancyGuard {
    IERC20 public immutable usdt;

    uint256 public constant EPOCH_DURATION = 28 days;
    uint256 public immutable deploymentTime;

    // 押金比例（basis points），买方押金 = 卖方押金 × ratio / 10000
    uint256 public depositRatioBasisPoints = 20000; // 默认 2:1

    uint256 public constant BASE_FEE_BP = 100;     // 1.00%
    uint256 public constant MIN_FEE_BP = 50;      // 0.50%

    uint256 public minAmountForSuccessCount = 50; // 50 USDT (整数单位)

    uint256 public feeBalance; // in USDT 整数单位

    uint256 public currentEpoch;

    struct Credit {
        uint32 successCountBuyer;       // 作为买方成功次数
        uint32 successCountSeller;      // 作为卖方成功次数
        uint64 successAmountBuyer;      // 作为买方累计金额 (USDT 整数)
        uint64 successAmountSeller;     // 作为卖方累计金额 (USDT 整数)
        uint32 pendingCount;            // 当前 pending 交易数 
        uint64 pendingAmount;           // 当前 pending 金额总和 (USDT 整数)
    }

    mapping(address => Credit) public credits;

    mapping(uint256 => mapping(address => uint256)) public epochSuccessAmount; // epoch → addr → USDT 整数单位

    enum TradeStatus { Created, Joined, Confirmed, Cancelled }

    struct Trade {
        address seller;
        address buyer;
        uint64 goodsAmount;        // 货款 (USDT 整数)
        uint64 sellerDeposit;
        uint64 buyerDeposit;
        uint64 fee;                // USDT 整数
        uint64 createTime;
        uint16 discountPercentage; // 0–10000
        TradeStatus status;
    }

    mapping(uint256 => Trade) public trades;
    uint256 public nextTradeId = 1;

    event TradeCreated(uint256 indexed tradeId, address seller, uint256 goodsAmount);
    event BuyerJoined(uint256 indexed tradeId, address buyer);
    event DiscountProposed(uint256 indexed tradeId, uint256 percentage);
    event TradeConfirmed(uint256 indexed tradeId);
    event TradeRefunded(uint256 indexed tradeId);
    event TradeCancelled(uint256 indexed tradeId);
    event DepositRatioUpdated(uint256 newRatioBP);
    event MinCountAmountUpdated(uint256 newAmount);

    error TradeDoesNotExist();
    error OnlySeller();
    error OnlyBuyer();
    error InvalidState();
    error InvalidAmounts();
    error InvalidDiscount();
    error AlreadyInFinalState();
    error NoFeesToWithdraw();
    error AmountExceedsLimit();

    constructor(address _usdt) Ownable(msg.sender) {
        usdt = IERC20(_usdt);
        deploymentTime = block.timestamp;
        currentEpoch = 0;
    }

    // ──────────────────────────────────────────────
    // Owner Functions
    // ──────────────────────────────────────────────

    function setDepositRatio(uint256 _ratioBasisPoints) external onlyOwner {
        require(_ratioBasisPoints >= 10000, "Ratio too low");
        depositRatioBasisPoints = _ratioBasisPoints;
        emit DepositRatioUpdated(_ratioBasisPoints);
    }

    function setMinAmountForCount(uint256 _newMin) external onlyOwner {
        minAmountForSuccessCount = _newMin;
        emit MinCountAmountUpdated(_newMin);
    }

    function withdrawFees(address to) external onlyOwner {
        uint256 amount = feeBalance * 1e6;
        if (amount == 0) revert NoFeesToWithdraw();
        feeBalance = 0;
        usdt.transfer(to, amount);
    }

    // ──────────────────────────────────────────────
    // Epoch & Fee Logic
    // ──────────────────────────────────────────────

    function _updateEpoch() internal {
        uint256 newEpoch = (block.timestamp - deploymentTime) / EPOCH_DURATION;
        if (newEpoch > currentEpoch) {
            currentEpoch = newEpoch;
        }
    }

    function getCurrentEpoch() public view returns (uint256) {
        return (block.timestamp - deploymentTime) / EPOCH_DURATION;
    }

    function getPrevEpochSuccess(address seller) public view returns (uint256) {
        uint256 prev = currentEpoch > 0 ? currentEpoch - 1 : 0;
        return epochSuccessAmount[prev][seller];
    }

    function getFeeRate(address seller) public view returns (uint256) {
        uint256 amountInLastEpoch = getPrevEpochSuccess(seller); // 已整数单位
        uint256 steps = amountInLastEpoch / 1000;
        uint256 rate = BASE_FEE_BP - (steps * 10);
        return rate < MIN_FEE_BP ? MIN_FEE_BP : rate;
    }

    // ──────────────────────────────────────────────
    // Trade Creation / Join / Cancel
    // ──────────────────────────────────────────────

    function createTrade(uint256 depositAmount, uint256 goodsAmount) external nonReentrant {
        if (goodsAmount < 1 || depositAmount < 1) revert InvalidAmounts();
        if (goodsAmount > type(uint64).max || depositAmount > type(uint64).max) revert AmountExceedsLimit();

        _updateEpoch();

        uint256 feeRate = getFeeRate(msg.sender);
        uint256 platformFee = (goodsAmount * feeRate) / 10000;

        if (platformFee > type(uint64).max) revert AmountExceedsLimit();

        uint256 totalUsdt = depositAmount + platformFee;
        if (totalUsdt > type(uint64).max) revert AmountExceedsLimit();

        uint256 totalWei = totalUsdt * 1e6;
        usdt.transferFrom(msg.sender, address(this), totalWei);

        feeBalance += platformFee;

        uint256 id = nextTradeId++;
        trades[id] = Trade({
            seller: msg.sender,
            buyer: address(0),
            goodsAmount: uint64(goodsAmount),
            sellerDeposit: uint64(depositAmount),
            buyerDeposit: 0,
            fee: uint64(platformFee),
            createTime: uint64(block.timestamp),
            discountPercentage: 0,
            status: TradeStatus.Created
        });

        emit TradeCreated(id, msg.sender, goodsAmount);
    }

    function cancelTrade(uint256 tradeId) external nonReentrant {
        Trade storage t = trades[tradeId];
        if (t.seller == address(0)) revert TradeDoesNotExist();
        if (msg.sender != t.seller) revert OnlySeller();
        if (t.status != TradeStatus.Created) revert InvalidState();

        feeBalance -= t.fee;
        uint256 totalUsdt = t.sellerDeposit + t.fee;
        uint256 totalWei = totalUsdt * 1e6;
        usdt.transfer(t.seller, totalWei);

        delete trades[tradeId];
        emit TradeCancelled(tradeId);
    }

    function joinTrade(uint256 tradeId) external nonReentrant {
        Trade storage t = trades[tradeId];
        if (t.seller == address(0)) revert TradeDoesNotExist();
        if (t.status != TradeStatus.Created) revert InvalidState();
        if (msg.sender == t.seller) revert OnlySeller();

        uint256 buyerDep = (t.sellerDeposit * depositRatioBasisPoints) / 10000;
        if (buyerDep > type(uint64).max) revert AmountExceedsLimit();

        uint256 totalUsdt = t.goodsAmount + buyerDep;
        if (totalUsdt > type(uint64).max) revert AmountExceedsLimit();

        uint256 totalWei = totalUsdt * 1e6;
        usdt.transferFrom(msg.sender, address(this), totalWei);

        t.buyer = msg.sender;
        t.buyerDeposit = uint64(buyerDep);
        t.status = TradeStatus.Joined;

        credits[msg.sender].pendingCount++;
        credits[msg.sender].pendingAmount += uint64(totalUsdt);
        credits[t.seller].pendingCount++;
        credits[t.seller].pendingAmount += uint64(t.goodsAmount + t.sellerDeposit);

        emit BuyerJoined(tradeId, msg.sender);
    }

    // ──────────────────────────────────────────────
    // Discount & Confirm
    // ──────────────────────────────────────────────

    function proposeDiscount(uint256 tradeId, uint256 percentage) external nonReentrant {
        Trade storage t = trades[tradeId];
        if (t.seller == address(0)) revert TradeDoesNotExist();
        if (msg.sender != t.seller) revert OnlySeller();
        if (t.status == TradeStatus.Confirmed || t.status == TradeStatus.Cancelled) revert AlreadyInFinalState();
        if (percentage > 10000) revert InvalidDiscount();

        t.discountPercentage = uint16(percentage);
        emit DiscountProposed(tradeId, percentage);
    }

    function confirmTrade(uint256 tradeId) external nonReentrant {
        Trade storage t = trades[tradeId];
        if (t.seller == address(0)) revert TradeDoesNotExist();
        if (msg.sender != t.buyer) revert OnlyBuyer();
        if (t.status != TradeStatus.Joined) revert InvalidState();

        uint256 discountAmt = (t.sellerDeposit * t.discountPercentage) / 10000;

        uint256 sellerUsdt = t.goodsAmount + t.sellerDeposit - discountAmt;
        uint256 buyerUsdt = t.buyerDeposit + discountAmt;

        usdt.transfer(t.seller, sellerUsdt * 1e6);
        usdt.transfer(t.buyer, buyerUsdt * 1e6);

        _updateSuccess(t.seller, t.goodsAmount, true);
        _updateSuccess(t.buyer, t.goodsAmount, false);

        _removePending(t.seller, t.goodsAmount + t.sellerDeposit);
        _removePending(t.buyer, t.goodsAmount + t.buyerDeposit);

        t.status = TradeStatus.Confirmed;
        emit TradeConfirmed(tradeId);
    }

    function refundBySellerAgreement(uint256 tradeId) external nonReentrant {
        Trade storage t = trades[tradeId];
        if (t.seller == address(0)) revert TradeDoesNotExist();
        if (msg.sender != t.seller) revert OnlySeller();
        if (t.status != TradeStatus.Joined) revert InvalidState();

        uint256 totalUsdt = t.goodsAmount + t.buyerDeposit + t.sellerDeposit;
        usdt.transfer(t.buyer, totalUsdt * 1e6);

        _removePending(t.seller, t.goodsAmount + t.sellerDeposit);
        _removePending(t.buyer, t.goodsAmount + t.buyerDeposit);

        t.status = TradeStatus.Cancelled;
        emit TradeRefunded(tradeId);
    }

    // ──────────────────────────────────────────────
    // Internal Helpers
    // ──────────────────────────────────────────────

    function _updateSuccess(address user, uint256 amount, bool isSeller) internal {
        _updateEpoch();

        epochSuccessAmount[currentEpoch][user] += amount;

        Credit storage c = credits[user];
        if (isSeller) {
            uint64 currentAmt = c.successAmountSeller;
            uint64 addAmt = uint64(amount);
            if (addAmt > type(uint64).max - currentAmt) {
                c.successAmountSeller = type(uint64).max;
            } else {
                c.successAmountSeller += addAmt;
            }
            if (amount >= minAmountForSuccessCount && c.successCountSeller < type(uint32).max) {
                c.successCountSeller++;
            }
        } else {
            uint64 currentAmt = c.successAmountBuyer;
            uint64 addAmt = uint64(amount);
            if (addAmt > type(uint64).max - currentAmt) {
                c.successAmountBuyer = type(uint64).max;
            } else {
                c.successAmountBuyer += addAmt;
            }
            if (amount >= minAmountForSuccessCount && c.successCountBuyer < type(uint32).max) {
                c.successCountBuyer++;
            }
        }
    }

    function _removePending(address user, uint256 amount) internal {
        Credit storage c = credits[user];
        if (c.pendingCount > 0) c.pendingCount--;
        if (c.pendingAmount >= amount) {
            c.pendingAmount -= uint64(amount);
        }
    }

    // ──────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────

    function getCredit(address user) external view returns (Credit memory) {
        return credits[user];
    }

    function getEpochSuccess(uint256 epoch, address user) external view returns (uint256) {
        return epochSuccessAmount[epoch][user];
    }

    function getTrade(uint256 tradeId) external view returns (Trade memory) {
        return trades[tradeId];
    }
}