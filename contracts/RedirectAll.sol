// SPDX-License-Identifier: MIT
pragma solidity ^0.7.1;
pragma abicoder v2;

import {
    ISuperfluid,
    ISuperToken,
    ISuperApp,
    ISuperAgreement,
    SuperAppDefinitions
} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";//"@superfluid-finance/ethereum-monorepo/packages/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

import {
    IConstantFlowAgreementV1
} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/IConstantFlowAgreementV1.sol";

import {
    SuperAppBase
} from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperAppBase.sol";

import "./TradeableCashflowStorage.sol";

contract RedirectAll is SuperAppBase {

    using TradeableCashflowStorage for TradeableCashflowStorage.AffiliateProgram;
    TradeableCashflowStorage.AffiliateProgram internal _ap;

    event ReceiverChanged(address receiver, uint tokenId);    // Emitted when the token is transfered and receiver is changed


    constructor(
        ISuperfluid host,
        IConstantFlowAgreementV1 cfa,
        ISuperToken acceptedToken,
        address owner) {
        require(address(host) != address(0), "host");
        require(address(cfa) != address(0), "cfa");
        require(address(acceptedToken) != address(0), "acceptedToken");
        require(address(owner) != address(0), "owner");
        require(!host.isApp(ISuperApp(owner)), "owner SA");

        _ap.host = host;
        _ap.cfa = cfa;
        _ap.acceptedToken = acceptedToken;
        _ap.owner = owner;

        uint256 configWord =
            SuperAppDefinitions.APP_LEVEL_FINAL |
            SuperAppDefinitions.BEFORE_AGREEMENT_CREATED_NOOP |
            SuperAppDefinitions.BEFORE_AGREEMENT_UPDATED_NOOP |
            SuperAppDefinitions.BEFORE_AGREEMENT_TERMINATED_NOOP;

        _ap.host.registerApp(configWord);
    }

    function getOwner() external view returns (address) {
      return _ap.owner;
    }


    // // Called after the contract has
    // function setTradeableCashflow(address tcfAddress) public {
    //   require(msg.sender == _ap.owner, "Only owner");
    //   // TODO: Require _tcf not set
    //   _tcf = ITradeableCashflow(tdfAddress);
    // }


    /**************************************************************************
     * Redirect Logic
     *************************************************************************/

    // function currentReceiver(uint tokenId)
    //     external view
    //     returns (
    //         uint256 startTime,
    //         address receiver,
    //         int96 flowRate
    //     )
    // {
    //   receiver = _ap.links[tokenId].owner;
    //   (startTime, flowRate,,) = _ap.cfa.getFlow(_ap.acceptedToken, address(this), receiver);
    // }

    /// @dev If a new stream is opened, or an existing one is opened
    function _updateOutflow(bytes calldata ctx)
        private
        returns (bytes memory newCtx)
    {
      address requester = _ap.host.decodeCtx(ctx).msgSender;
      newCtx = ctx;

      uint tokenId = _ap.referrals[requester];
      require(tokenId != 0, "no registration");


      // Compare current and previous net flow rates to see what was add/removed
      int96 inFlowRate = _ap.cfa.getNetFlow(_ap.acceptedToken, address(this)); // - _ap.lastNetFlowRate;  // TODO: does this work to get the
      // _ap.lastNetFlowRate = _ap.cfa.getNetFlow(_ap.acceptedToken, address(this));
      // NOTE: inFlowRate can be negative if the update is a closing of a stream?


      (,int96 ownerOutflowRate,,) = _ap.cfa.getFlow(_ap.acceptedToken, address(this), _ap.owner); //CHECK: unclear what happens if flow doesn't exist.
      (,int96 holderOutflowRate,,) = _ap.cfa.getFlow(_ap.acceptedToken, address(this), _ap.links[tokenId].owner); //CHECK: unclear what happens if flow doesn't exist.


      // Next split this into 80/20
      // TODO: Safemath needs to be here for sure
      int96 ownerInFlowRate;
      int96 holderInFlowRate;
      if (inFlowRate == 0) {
        ownerInFlowRate = 0;
        holderInFlowRate = 0;
      } else {
        _ap.links[tokenId].outflowRate = inFlowRate;
        ownerInFlowRate = ownerOutflowRate + (inFlowRate * 8000 / 10000);
        holderInFlowRate = holderOutflowRate + (inFlowRate * 2000 / 10000);
      }

      // TODO: Verify this if-else chain works

      if (ownerOutflowRate == int96(0)) {
        newCtx = _createFlow(_ap.owner, ownerInFlowRate, newCtx);
      } else if (ownerInFlowRate == int96(0)) {
        newCtx = _deleteFlow(address(this), _ap.owner, newCtx);
      } else {
        newCtx = _updateFlow(_ap.owner, ownerInFlowRate, newCtx);
      }

      if (holderOutflowRate == int96(0)) {
        newCtx = _createFlow(_ap.links[tokenId].owner, holderInFlowRate, newCtx);
      } else if (holderInFlowRate == int96(0)) {
        newCtx = _deleteFlow(address(this), _ap.links[tokenId].owner, newCtx);
      } else {
        newCtx = _updateFlow(_ap.links[tokenId].owner, holderInFlowRate, newCtx);
      }

    }

    // @dev Change the Receiver of the total flow
    function _changeReceiver( address from, address newReceiver, uint tokenId) internal {
        require(newReceiver != address(0), "zero addr");
        // @dev because our app is registered as final, we can't take downstream apps
        require(!_ap.host.isApp(ISuperApp(newReceiver)), "SA addr");
        if (newReceiver == from) return ;

        // This gets the current outflowRate of the newReceiver (can be 0 if no flow)
        (,int96 oldOwnerOutflowRate,,) = _ap.cfa.getFlow(_ap.acceptedToken, address(this), from);

        // If the newReceiver already has a flow, update it adding tokenOutflow
        // from the newly acquired token
        require( _ap.links[tokenId].outflowRate > 0, "!flow");
        _createFlow(newReceiver, oldOwnerOutflowRate);


        // NOTE: This is a hack where we assume each owner has 1 NFT
        //       So all I do now is just delete the flow to the previous holder
        _deleteFlow(address(this), from);


        // // Lastly, update the owner on the token
        _ap.links[tokenId].owner = newReceiver;
        emit ReceiverChanged(newReceiver, tokenId);
    }

    /**************************************************************************
     * SuperApp callbacks
     *************************************************************************/

    function afterAgreementCreated(
        ISuperToken _superToken,
        address _agreementClass,
        bytes32, // _agreementId,
        bytes calldata /*_agreementData*/,
        bytes calldata ,// _cbdata,
        bytes calldata _ctx
    )
        external override
        onlyExpected(_superToken, _agreementClass)
        onlyHost
        returns (bytes memory newCtx)
    {
        return _updateOutflow(_ctx);
    }

    function afterAgreementUpdated(
        ISuperToken _superToken,
        address _agreementClass,
        bytes32 ,//_agreementId,
        bytes calldata , //agreementData,
        bytes calldata ,//_cbdata,
        bytes calldata _ctx
    )
        external override
        onlyExpected(_superToken, _agreementClass)
        onlyHost
        returns (bytes memory newCtx)
    {
        return _updateOutflow(_ctx);
    }

    function afterAgreementTerminated(
        ISuperToken _superToken,
        address _agreementClass,
        bytes32 ,//_agreementId,
        bytes calldata /*_agreementData*/,
        bytes calldata ,//_cbdata,
        bytes calldata _ctx
    )
        external override
        onlyHost
        returns (bytes memory newCtx)
    {
        // According to the app basic law, we should never revert in a termination callback
        if (!_isSameToken(_superToken) || !_isCFAv1(_agreementClass)) return _ctx;
        return _updateOutflow(_ctx);
    }

    function _isSameToken(ISuperToken superToken) internal view returns (bool) {
        return address(superToken) == address(_ap.acceptedToken);
    }

    function _isCFAv1(address agreementClass) internal view returns (bool) {
        return ISuperAgreement(agreementClass).agreementType()
            == keccak256("org.superfluid-finance.agreements.ConstantFlowAgreement.v1");
    }

    modifier onlyHost() {
        require(msg.sender == address(_ap.host), "one host");
        _;
    }

    modifier onlyExpected(ISuperToken superToken, address agreementClass) {
        require(_isSameToken(superToken), "not accepted");
        require(_isCFAv1(agreementClass), "v1 supported");
        _;
    }


    function _createFlow(address to, int96 flowRate) internal {
       _ap.host.callAgreement(
           _ap.cfa,
           abi.encodeWithSelector(
               _ap.cfa.createFlow.selector,
               _ap.acceptedToken,
               to,
               flowRate,
               new bytes(0) // placeholder
           ),
           "0x"
       );
    }


    function _createFlow(
        address to,
        int96 flowRate,
        bytes memory ctx
    ) internal returns (bytes memory newCtx) {
        (newCtx, ) = _ap.host.callAgreementWithContext(
            _ap.cfa,
            abi.encodeWithSelector(
                _ap.cfa.createFlow.selector,
                _ap.acceptedToken,
                to,
                flowRate,
                new bytes(0) // placeholder
            ),
            "0x",
            ctx
        );
    }

    function _updateFlow(address to, int96 flowRate) internal {
        _ap.host.callAgreement(
            _ap.cfa,
            abi.encodeWithSelector(
                _ap.cfa.updateFlow.selector,
                _ap.acceptedToken,
                to,
                flowRate,
                new bytes(0) // placeholder
            ),
            "0x"
        );
    }

    function _updateFlow(
        address to,
        int96 flowRate,
        bytes memory ctx
    ) internal returns (bytes memory newCtx) {
        (newCtx, ) = _ap.host.callAgreementWithContext(
            _ap.cfa,
            abi.encodeWithSelector(
                _ap.cfa.updateFlow.selector,
                _ap.acceptedToken,
                to,
                flowRate,
                new bytes(0) // placeholder
            ),
            "0x",
            ctx
        );
    }

    function _deleteFlow(address from, address to) internal {
        _ap.host.callAgreement(
            _ap.cfa,
            abi.encodeWithSelector(
                _ap.cfa.deleteFlow.selector,
                _ap.acceptedToken,
                from,
                to,
                new bytes(0) // placeholder
            ),
            "0x"
        );
    }

    function _deleteFlow(
        address from,
        address to,
        bytes memory ctx
    ) internal returns (bytes memory newCtx) {
        (newCtx, ) = _ap.host.callAgreementWithContext(
            _ap.cfa,
            abi.encodeWithSelector(
                _ap.cfa.deleteFlow.selector,
                _ap.acceptedToken,
                from,
                to,
                new bytes(0) // placeholder
            ),
            "0x",
            ctx
        );
    }


}
