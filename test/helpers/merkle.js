const { ethers } = require("hardhat");

/**
 * Simple Merkle tree implementation for testing
 */
class MerkleTree {
  constructor(leaves) {
    this.leaves = leaves.map(leaf => this.hashLeaf(leaf));
    this.tree = this.buildTree(this.leaves);
  }

  hashLeaf(data) {
    return ethers.keccak256(data);
  }

  hashPair(a, b) {
    return ethers.keccak256(
      ethers.solidityPacked(["bytes32", "bytes32"], [a < b ? a : b, a < b ? b : a])
    );
  }

  buildTree(leaves) {
    if (leaves.length === 0) return [];
    if (leaves.length === 1) return [leaves];

    const tree = [leaves];
    let currentLevel = leaves;

    while (currentLevel.length > 1) {
      const nextLevel = [];
      
      for (let i = 0; i < currentLevel.length; i += 2) {
        if (i + 1 < currentLevel.length) {
          nextLevel.push(this.hashPair(currentLevel[i], currentLevel[i + 1]));
        } else {
          nextLevel.push(currentLevel[i]);
        }
      }

      tree.push(nextLevel);
      currentLevel = nextLevel;
    }

    return tree;
  }

  getRoot() {
    if (this.tree.length === 0) return ethers.ZeroHash;
    return this.tree[this.tree.length - 1][0];
  }

  getProof(index) {
    if (index >= this.leaves.length) {
      throw new Error("Index out of bounds");
    }

    const proof = [];
    let currentIndex = index;

    for (let level = 0; level < this.tree.length - 1; level++) {
      const levelSize = this.tree[level].length;
      const isRightNode = currentIndex % 2 === 1;
      const siblingIndex = isRightNode ? currentIndex - 1 : currentIndex + 1;

      if (siblingIndex < levelSize) {
        proof.push(this.tree[level][siblingIndex]);
      }

      currentIndex = Math.floor(currentIndex / 2);
    }

    return proof;
  }

  verify(proof, leaf, root) {
    let computedHash = this.hashLeaf(leaf);

    for (const proofElement of proof) {
      computedHash = this.hashPair(computedHash, proofElement);
    }

    return computedHash === root;
  }
}

/**
 * Create a trade data structure for Merkle tree
 */
function createTradeData(traderId, symbol, pnl, volume, timestamp) {
  return ethers.AbiCoder.defaultAbiCoder().encode(
    ["bytes32", "bytes32", "int256", "uint256", "uint256"],
    [traderId, symbol, pnl, volume, timestamp]
  );
}

module.exports = {
  MerkleTree,
  createTradeData
};
