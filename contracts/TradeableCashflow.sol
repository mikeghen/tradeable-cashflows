//SPDX-License-Identifier: MIT
pragma solidity ^0.7.1;
pragma abicoder v2;

import {RedirectAll, ISuperToken, IConstantFlowAgreementV1, ISuperfluid} from "./RedirectAll.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "./TradeableCashflowStorage.sol";


contract TradeableCashflow is ERC721, RedirectAll {

  using Counters for Counters.Counter;
  Counters.Counter tokenIds;

  using TradeableCashflowStorage for TradeableCashflowStorage.Link;

  event NewAffiliateLink(uint tokenId, address owner);      // Emitted when a new affiliate link is created

  constructor (
    address owner,
    string memory _name,
    string memory _symbol,
    ISuperfluid host,
    IConstantFlowAgreementV1 cfa,
    ISuperToken acceptedToken
  )
    ERC721 ( _name, _symbol )
    RedirectAll (
      host,
      cfa,
      acceptedToken,
      owner
     )
  {

    // makeAffiliateLink("1", 3858);

  }


  // @dev Makes a new affiliate link and mints an NFT to the msg.sender
  // @notice The tokenID is to be used as the affiliate code
  // @return tokenId of the newly minted NFT
  function makeAffiliateLink(address owner, string memory tokenUri, int96 outflowRate) public returns (uint tokenId) {
    require(owner != _ap.owner, "!owner");

    tokenIds.increment();
    tokenId = tokenIds.current();

    _mint(owner, tokenId);
    // _setTokenURI(tokenId, tokenUri);

    _ap.links[tokenId] = TradeableCashflowStorage.Link(outflowRate, owner);

  }

  // @notice The tokenID is to be used as the affiliate code
  // @param tokenId
  // function getAfflilateLink(uint tokenId) external returns (TradeableCashflowStorage.Link memory link) {
  //   return _ap.links[tokenId];
  // }


  // @dev Register a referral, associating the address of the subscriber with a tokenId
  // @param refered The address of the referred subscriber
  // @param tokenId The token to associate this referral tool
  function registerReferral(address referred, uint tokenId) external {
    require(_ap.referrals[referred] == 0, "ref");
    _ap.referrals[referred] = tokenId;
  }


  function _beforeTokenTransfer(
    address from,
    address to,
    uint256 tokenId
  ) internal override {
      if (from != address(0)) {
        _changeReceiver(from, to, tokenId);
      }
  }






}
