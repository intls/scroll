// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IL2ERC20Gateway, L2ERC20Gateway } from "./L2ERC20Gateway.sol";
import { IL2ScrollMessenger } from "../IL2ScrollMessenger.sol";
import { IWETH } from "../../interfaces/IWETH.sol";
import { IL1ERC20Gateway } from "../../L1/gateways/IL1ERC20Gateway.sol";
import { ScrollGatewayBase, IScrollGateway } from "../../libraries/gateway/ScrollGatewayBase.sol";

/// @title L2WETHGateway
/// @notice The `L2WETHGateway` contract is used to withdraw `WETH` token in layer 2 and
/// finalize deposit `WETH` from layer 1.
/// @dev The WETH tokens are not held in the gateway. It will first be unwrapped as Ether and
/// then the Ether will be sent to the `L2ScrollMessenger` contract.
/// On finalizing deposit, the Ether will be transfered from `L2ScrollMessenger`, then
/// wrapped as WETH and finally transfer to recipient.
contract L2WETHGateway is Initializable, ScrollGatewayBase, L2ERC20Gateway {
  using SafeERC20 for IERC20;

  /**************************************** Variables ****************************************/

  /// @notice The address of L1 WETH address.
  address public l1WETH;

  /// @notice The address of L2 WETH address.
  // @todo It should be predeployed in L2 and make it a constant.
  // solhint-disable-next-line var-name-mixedcase
  address public WETH;

  /**************************************** Constructor ****************************************/

  function initialize(
    address _counterpart,
    address _router,
    address _messenger,
    // solhint-disable-next-line var-name-mixedcase
    address _WETH,
    address _l1WETH
  ) external initializer {
    require(_router != address(0), "zero router address");
    ScrollGatewayBase._initialize(_counterpart, _router, _messenger);

    require(_WETH != address(0), "zero WETH address");
    require(_l1WETH != address(0), "zero L1WETH address");

    WETH = _WETH;
    l1WETH = _l1WETH;
  }

  receive() external payable {
    require(msg.sender == WETH, "only WETH");
  }

  /**************************************** View Functions ****************************************/

  /// @inheritdoc IL2ERC20Gateway
  function getL1ERC20Address(address) external view override returns (address) {
    return l1WETH;
  }

  /// @inheritdoc IL2ERC20Gateway
  function getL2ERC20Address(address) public view override returns (address) {
    return WETH;
  }

  /**************************************** Mutate Functions ****************************************/

  /// @inheritdoc IL2ERC20Gateway
  function finalizeDepositERC20(
    address _l1Token,
    address _l2Token,
    address _from,
    address _to,
    uint256 _amount,
    bytes calldata _data
  ) external payable override onlyCallByCounterpart {
    require(_l1Token == l1WETH, "l1 token not WETH");
    require(_l2Token == WETH, "l2 token not WETH");
    require(_amount == msg.value, "msg.value mismatch");

    IWETH(_l2Token).deposit{ value: _amount }();
    IERC20(_l2Token).safeTransfer(_to, _amount);

    // @todo forward `_data` to `_to` in near future

    emit FinalizeDepositERC20(_l1Token, _l2Token, _from, _to, _amount, _data);
  }

  /// @inheritdoc IScrollGateway
  function finalizeDropMessage() external payable virtual onlyMessenger {
    // @todo should refund token back to sender.
  }

  /**************************************** Internal Functions ****************************************/

  /// @inheritdoc L2ERC20Gateway
  function _withdraw(
    address _token,
    address _to,
    uint256 _amount,
    bytes memory _data,
    uint256 _gasLimit
  ) internal virtual override {
    require(_amount > 0, "withdraw zero amount");
    require(_token == WETH, "only WETH is allowed");

    // 1. Extract real sender if this call is from L1GatewayRouter.
    address _from = msg.sender;
    if (router == msg.sender) {
      (_from, _data) = abi.decode(_data, (address, bytes));
    }

    // 2. Transfer token into this contract.
    IERC20(_token).safeTransferFrom(_from, address(this), _amount);
    IWETH(_token).withdraw(_amount);

    // 3. Generate message passed to L2StandardERC20Gateway.
    address _l1WETH = l1WETH;
    bytes memory _message = abi.encodeWithSelector(
      IL1ERC20Gateway.finalizeWithdrawERC20.selector,
      _l1WETH,
      _token,
      _from,
      _to,
      _amount,
      _data
    );

    // 4. Send message to L1ScrollMessenger.
    IL2ScrollMessenger(messenger).sendMessage{ value: _amount + msg.value }(
      counterpart,
      msg.value,
      _message,
      _gasLimit
    );

    emit WithdrawERC20(_l1WETH, _token, _from, _to, _amount, _data);
  }
}