// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";

interface IUnStZETA is IERC721Upgradeable {
    /// @notice mint a nwe NFT to _to address.
    /// @param _to NFT holder
    /// @return tokenId return token id.
    function mint(address _to) external returns (uint256);

    /// @notice burn a NFT from _to address.
    /// @param _tokenId token id.
    function burn(uint256 _tokenId) external;

    /// @notice check if address is owner or approved
    /// @param _spender check address.
    /// @param _tokenId token id.
    /// @return result return result
    function isApprovedOrOwner(address _spender, uint256 _tokenId)
        external
        view
        returns (bool);

    /// @notice set stZETA address.
    /// @param _stZETA new stZETA address.
    function setStZETA(address _stZETA) external;

    /// @notice list address all owned tokenid
    /// @param _owner check address.
    /// @return result return tokenid list.
    function getOwnedTokens(address _owner) external view returns (uint256[] memory);

    /// @notice togle pause and unpause
    function togglePause() external;

    /// @notice set new version
    /// @param _newVersion new version
    function setVersion(string calldata _newVersion) external;

    /// @notice get update version
    function getUpdateVersion() external pure returns(string memory);

    /// @notice check tokenid exists
    /// @param _tokenId token id.
    /// @return result return result
    function exists(uint256 _tokenId) external view returns (bool);

}