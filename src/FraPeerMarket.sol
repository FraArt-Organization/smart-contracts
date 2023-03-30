// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../custom-lib/Auth.sol";

contract FraPeerMarket is ReentrancyGuard, Auth {
    using Address for address;
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    uint256 public fee;
    address public marketer;
    uint256 constant _UNIT = 10000;
    uint256 currentOrderId = 0;
    struct BookOrder {
        uint256 id;
        address bookToken;
        uint256 bookAmount;
        uint256 bookPrice;
        address seller;
        bool status;
    }
    mapping (uint256 => BookOrder) public bookOrders;
    // seller => (bookToken => orderId)
    mapping (address => mapping(address => uint256)) public userBook;
    
    constructor() Auth(msg.sender) {
        marketer = msg.sender;
        fee = 250; // 2.5%, unit = 10000
    }

    function setMarketer(address _marketer) external authorized {
        require(_marketer != address(0), "Invalid address");
        marketer = _marketer;
    }

    function setFee(uint256 _fee) external authorized {
        require(_fee < _UNIT, "Exceed max fee");
        fee = _fee;
    }

    function checkBookOrder(address _user, address _bookToken) public view returns(BookOrder memory _bookOrder) {
        if (userBook[_user][_bookToken] == type(uint256).max || userBook[_user][_bookToken] == 0) revert("Not found");
        return bookOrders[userBook[_user][_bookToken]];
    }

    function createOrder(address _bookToken, uint256 _bookAmount, uint256 _bookPrice) public returns (uint256) {
        address _seller = msg.sender;
        require(_bookAmount > 0 && _bookPrice > 0, "Invalid order");
        require(userBook[_seller][_bookToken] == 0 || userBook[_seller][_bookToken] == type(uint256).max, "You have an order already");
        IERC20(_bookToken).transferFrom(_seller, address(this), _bookAmount);
        currentOrderId = currentOrderId.add(1);
        BookOrder memory order;
        order.id = currentOrderId;
        order.bookToken = _bookToken;
        order.bookAmount = _bookAmount;
        order.bookPrice = _bookPrice;
        order.seller = _seller;
        order.status = true;
        bookOrders[currentOrderId] = order;
        userBook[_seller][_bookToken] = currentOrderId;
        emit CreateOrder(currentOrderId, _bookToken, _bookAmount, _bookPrice, _seller);
        return currentOrderId;
    }

    function executeOrder(uint256 _orderId, uint256 _requiredBookAmount) external payable nonReentrant {
        address payable _buyer = payable(msg.sender);
        require(_requiredBookAmount > 0, "invalid amount");
        require(_orderId > 0 && _orderId != type(uint256).max && bookOrders[_orderId].status, "inactive order");
        BookOrder memory order = bookOrders[_orderId];
        require(order.bookAmount >= _requiredBookAmount, "insufficient liquidity");
        uint256 _requiredExecAmount = _requiredBookAmount.mul(order.bookPrice);
        require(msg.value >= _requiredExecAmount, "insufficient balance");
        uint256 _requiredExecFeeAmount = _requiredExecAmount.mul(fee) / _UNIT;
        uint256 _requiredExecNetAmount = _requiredExecAmount - _requiredExecFeeAmount;
        IERC20(bookOrders[_orderId].bookToken).approve(address(this), _requiredBookAmount);
        IERC20(order.bookToken).safeTransferFrom(address(this), _buyer, _requiredBookAmount);
        payable(marketer).transfer(_requiredExecFeeAmount);
        payable(order.seller).transfer(_requiredExecNetAmount);
        if (order.bookAmount <= _requiredBookAmount) {
            order.bookAmount = 0;
            order.status = false;
        } else {
            order.bookAmount = order.bookAmount.sub(_requiredBookAmount);
        }
        bookOrders[_orderId] = order;
        emit TradeOrder(_orderId, _requiredBookAmount, _buyer);
    }

    function updateOrder(uint256 _orderId, uint256 _bookAmount, uint256 _bookPrice) public nonReentrant {
        address _seller = msg.sender;
        BookOrder memory order = bookOrders[_orderId];
        require(userBook[_seller][order.bookToken] == _orderId && order.status, "Unavailable Order");
        if (order.bookAmount > _bookAmount) {
            uint256 _amount = order.bookAmount.sub(_bookAmount);
            IERC20(order.bookToken).transferFrom(address(this), order.seller, _amount);
        } else if (order.bookAmount < _bookAmount) {
            uint256 _amount = order.bookAmount.sub(_bookAmount);
            IERC20(order.bookToken).transferFrom(order.seller, address(this), _amount);
        }
        order.bookAmount = _bookAmount;
        order.bookPrice = _bookPrice;
        bookOrders[_orderId] = order;
        emit UpdateOrder(_orderId, _bookAmount, _bookPrice);
    }

    function cancelOrder(uint256 _orderId) public nonReentrant {
        address _seller = msg.sender;
        BookOrder memory order = bookOrders[_orderId];
        require(userBook[_seller][order.bookToken] == _orderId && order.status, "Unavailable Order");
        userBook[_seller][order.bookToken] = type(uint256).max;
        order.status = false;
        uint256 _availableAmount = order.bookAmount;
        order.bookAmount = 0;
        IERC20(bookOrders[_orderId].bookToken).approve(address(this), _availableAmount);
        IERC20(bookOrders[_orderId].bookToken).safeTransferFrom(address(this), _seller, _availableAmount);
        bookOrders[_orderId] = order;
        emit CancelOrder(_orderId);
    }

    event CreateOrder(uint256 indexed _orderId, address indexed _bookToken, uint256 _bookAmount, uint256 _bookPrice, address _seller);
    event UpdateOrder(uint256 indexed _orderId, uint256 _bookAmount, uint256 _bookPrice);
    event TradeOrder(uint256 indexed _orderId, uint256 _execAmount, address _buyer);
    event CancelOrder(uint256 indexed _orderId);
}