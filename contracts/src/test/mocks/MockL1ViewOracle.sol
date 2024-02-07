// SPDX-License-Identifier: MIT

pragma solidity =0.8.16;

contract MockL1ViewOracle {
    function blockRangeHash(uint256, uint256) external view returns (bytes32 hash_) {
        // Make a call to simulate the behaviour of the L1 View Oracle
        blockhash(1);
        // Return the mocked value
        hash_ = 0xb10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf6;
    }
}
