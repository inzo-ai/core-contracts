// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC721 {
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    function balanceOf(address owner) external view returns (uint256 balance);
    function ownerOf(uint256 tokenId) external view returns (address owner);
    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external;
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function transferFrom(address from, address to, uint256 tokenId) external;
    function approve(address to, uint256 tokenId) external;
    function setApprovalForAll(address operator, bool approved) external;
    function getApproved(uint256 tokenId) external view returns (address operator);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) external returns (bytes4);
}

interface IERC721Metadata {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function tokenURI(uint256 tokenId) external view returns (string memory);
}

contract PolicyNFT is IERC721, IERC721Metadata {
    string private _name;
    string private _symbol;

    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;
    mapping(uint256 => string) private _tokenURIs;

    uint256 private _nextTokenId;
    address public policyManagerContract; 

    modifier onlyPolicyManager() {
        require(msg.sender == policyManagerContract, "PolicyNFT: Caller is not the policy manager");
        _;
    }

    constructor(string memory contractNftName, string memory contractNftSymbol, address initialPolicyManager) {
        _name = contractNftName;
        _symbol = contractNftSymbol;
        policyManagerContract = initialPolicyManager;
        _nextTokenId = 1; 
    }

    function supportsInterface(bytes4 interfaceId) external view virtual override returns (bool) {
        return
            interfaceId == type(IERC721).interfaceId ||
            interfaceId == type(IERC721Metadata).interfaceId;
    }

    function name() external view virtual override returns (string memory) {
        return _name;
    }

    function symbol() external view virtual override returns (string memory) {
        return _symbol;
    }

    function tokenURI(uint256 tokenId) external view virtual override returns (string memory) {
        require(_exists(tokenId), "PolicyNFT: URI query for nonexistent token");
        return _tokenURIs[tokenId];
    }

    function _setTokenURI(uint256 tokenId, string memory uri) internal virtual {
        require(_exists(tokenId), "PolicyNFT: URI set for nonexistent token");
        _tokenURIs[tokenId] = uri;
    }
    
    function updateTokenURI(uint256 tokenId, string memory newUri) external virtual onlyPolicyManager {
        _setTokenURI(tokenId, newUri);
    }

    function balanceOf(address owner) external view virtual override returns (uint256) {
        require(owner != address(0), "PolicyNFT: Balance query for the zero address");
        return _balances[owner];
    }

    function ownerOf(uint256 tokenId) public view virtual override returns (address) {
        address owner = _owners[tokenId];
        require(owner != address(0), "PolicyNFT: Owner query for nonexistent token");
        return owner;
    }

    function approve(address to, uint256 tokenId) external virtual override {
        address owner = ownerOf(tokenId);
        require(to != owner, "PolicyNFT: Approval to current owner");
        require(msg.sender == owner || isApprovedForAll(owner, msg.sender), "PolicyNFT: Approve caller is not owner nor approved for all");
        _approve(to, tokenId);
    }

    function _approve(address to, uint256 tokenId) internal virtual {
        _tokenApprovals[tokenId] = to;
        emit Approval(ownerOf(tokenId), to, tokenId);
    }

    function getApproved(uint256 tokenId) external view virtual override returns (address) {
        require(_exists(tokenId), "PolicyNFT: Approved query for nonexistent token");
        return _tokenApprovals[tokenId];
    }

    function setApprovalForAll(address operator, bool approved) external virtual override {
        require(operator != msg.sender, "PolicyNFT: Approve to caller");
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function isApprovedForAll(address owner, address operator) public view virtual override returns (bool) {
        return _operatorApprovals[owner][operator];
    }

    function transferFrom(address from, address to, uint256 tokenId) external virtual override {
        require(_isApprovedOrOwner(msg.sender, tokenId), "PolicyNFT: Transfer caller is not owner nor approved");
        _transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external virtual override {
        safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public virtual override {
        require(_isApprovedOrOwner(msg.sender, tokenId), "PolicyNFT: Transfer caller is not owner nor approved");
        _safeTransfer(from, to, tokenId, data);
    }

    function _safeTransfer(address from, address to, uint256 tokenId, bytes memory data) internal virtual {
        _transfer(from, to, tokenId);
        require(_checkOnERC721Received(from, to, tokenId, data), "PolicyNFT: Transfer to non ERC721Receiver implementer");
    }

    function _exists(uint256 tokenId) internal view virtual returns (bool) {
        return _owners[tokenId] != address(0);
    }

    function _isApprovedOrOwner(address spender, uint256 tokenId) internal view virtual returns (bool) {
        require(_exists(tokenId), "PolicyNFT: Operator query for nonexistent token");
        address owner = ownerOf(tokenId);
        return (spender == owner || _tokenApprovals[tokenId] == spender || isApprovedForAll(owner, spender));
    }
    
    function _checkOnERC721Received(address from, address to, uint256 tokenId, bytes memory data) private returns (bool) {
        if (to.code.length > 0) {
            try IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data) returns (bytes4 retval) {
                return retval == IERC721Receiver.onERC721Received.selector;
            } catch Error(string memory reason) {
                revert(reason);
            } catch (bytes memory reason) {
                if (reason.length == 0) {
                    revert("PolicyNFT: Transfer to non ERC721Receiver implementer");
                } else {
                    assembly {
                        revert(add(32, reason), mload(reason))
                    }
                }
            }
        } else {
            return true;
        }
    }

    function _mint(address to, uint256 tokenId) internal virtual {
        require(to != address(0), "PolicyNFT: Mint to the zero address");
        require(!_exists(tokenId), "PolicyNFT: Token already minted");

        _owners[tokenId] = to;
        _balances[to] += 1;

        emit Transfer(address(0), to, tokenId);
    }

    function mintPolicyNFT(address recipient, string memory uri) external virtual onlyPolicyManager returns (uint256) {
        uint256 newTokenId = _nextTokenId;
        _mint(recipient, newTokenId);
        _setTokenURI(newTokenId, uri);
        _nextTokenId++;
        return newTokenId;
    }

    function _burn(uint256 tokenId) internal virtual {
        address owner = ownerOf(tokenId);

        _approve(address(0), tokenId); 

        _balances[owner] -= 1;
        delete _owners[tokenId];
        delete _tokenURIs[tokenId];

        emit Transfer(owner, address(0), tokenId);
    }

    function burnPolicyNFT(uint256 tokenId) external virtual {
        require(_isApprovedOrOwner(msg.sender, tokenId) || msg.sender == policyManagerContract, "PolicyNFT: Caller is not owner, approved, or policy manager");
        _burn(tokenId);
    }
    
    function setPolicyManager(address newPolicyManager) external {
        require(msg.sender == policyManagerContract, "PolicyNFT: Only current manager can change manager");
        require(newPolicyManager != address(0), "PolicyNFT: New manager is zero address");
        policyManagerContract = newPolicyManager;
    }

    function _transfer(address from, address to, uint256 tokenId) internal virtual {
        require(ownerOf(tokenId) == from, "PolicyNFT: Transfer from incorrect owner");
        require(to != address(0), "PolicyNFT: Transfer to the zero address");

        _approve(address(0), tokenId); 

        _balances[from] -= 1;
        _balances[to] += 1;
        _owners[tokenId] = to;

        emit Transfer(from, to, tokenId);
    }
}