// SPDX-License-Identifier: MIT

pragma solidity =0.8.16;

import {DSTestPlus} from "solmate/test/utils/DSTestPlus.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {L1MessageQueue} from "../L1/rollup/L1MessageQueue.sol";
import {L1ViewOracle} from "../L1/L1ViewOracle.sol";
import {ScrollChain, IScrollChain} from "../L1/rollup/ScrollChain.sol";

import {MockScrollChain} from "./mocks/MockScrollChain.sol";
import {MockRollupVerifier} from "./mocks/MockRollupVerifier.sol";

// solhint-disable no-inline-assembly

contract ScrollChainTest is DSTestPlus {
    // from ScrollChain
    event UpdateSequencer(address indexed account, bool status);
    event UpdateProver(address indexed account, bool status);
    event UpdateVerifier(address indexed oldVerifier, address indexed newVerifier);
    event UpdateMaxNumTxInChunk(uint256 oldMaxNumTxInChunk, uint256 newMaxNumTxInChunk);

    event CommitBatch(uint256 indexed batchIndex, bytes32 indexed batchHash);
    event FinalizeBatch(uint256 indexed batchIndex, bytes32 indexed batchHash, bytes32 stateRoot, bytes32 withdrawRoot);
    event RevertBatch(uint256 indexed batchIndex, bytes32 indexed batchHash);

    L1ViewOracle private l1ViewOracle;
    ScrollChain private rollup;
    L1MessageQueue internal messageQueue;
    MockScrollChain internal chain;
    MockRollupVerifier internal verifier;

    function setUp() public {
        l1ViewOracle = new L1ViewOracle();
        messageQueue = L1MessageQueue(address(new ERC1967Proxy(address(new L1MessageQueue()), new bytes(0))));
        rollup = ScrollChain(address(new ERC1967Proxy(address(new ScrollChain(233)), new bytes(0))));
        verifier = new MockRollupVerifier();

        rollup.initialize(address(messageQueue), address(verifier), 100, address(l1ViewOracle));
        messageQueue.initialize(address(this), address(rollup), address(0), address(0), 1000000);

        chain = new MockScrollChain();
    }

    function testInitialized() public {
        assertEq(address(this), rollup.owner());
        assertEq(rollup.layer2ChainId(), 233);

        hevm.expectRevert("Initializable: contract is already initialized");
        rollup.initialize(address(messageQueue), address(0), 100, address(l1ViewOracle));
    }

    function testCommitBatch() public {
        bytes memory batchHeader0 = new bytes(129);

        // import 10 L1 messages
        for (uint256 i = 0; i < 10; i++) {
            messageQueue.appendCrossDomainMessage(address(this), 1000000, new bytes(0));
        }

        // import genesis batch first
        assembly {
            mstore(add(batchHeader0, add(0x20, 25)), 1)
        }
        rollup.importGenesisBatch(batchHeader0, bytes32(uint256(1)));

        // caller not sequencer, revert
        hevm.expectRevert("caller not sequencer");
        rollup.commitBatch(0, batchHeader0, new bytes[](0), new bytes(0), 0);

        rollup.addSequencer(address(0));

        // invalid version, revert
        hevm.startPrank(address(0));
        hevm.expectRevert("invalid version");
        rollup.commitBatch(1, batchHeader0, new bytes[](0), new bytes(0), 0);
        hevm.stopPrank();

        // batch is empty, revert
        hevm.startPrank(address(0));
        hevm.expectRevert("batch is empty");
        rollup.commitBatch(0, batchHeader0, new bytes[](0), new bytes(0), 0);
        hevm.stopPrank();

        // batch header length too small, revert
        hevm.startPrank(address(0));
        hevm.expectRevert("batch header length too small");
        rollup.commitBatch(0, new bytes(128), new bytes[](1), new bytes(0), 0);
        hevm.stopPrank();

        // wrong bitmap length, revert
        hevm.startPrank(address(0));
        hevm.expectRevert("wrong bitmap length");
        rollup.commitBatch(0, new bytes(130), new bytes[](1), new bytes(0), 0);
        hevm.stopPrank();

        // incorrect parent batch hash, revert
        assembly {
            mstore(add(batchHeader0, add(0x20, 25)), 2) // change data hash for batch0
        }
        hevm.startPrank(address(0));
        hevm.expectRevert("incorrect parent batch hash");
        rollup.commitBatch(0, batchHeader0, new bytes[](1), new bytes(0), 0);
        hevm.stopPrank();
        assembly {
            mstore(add(batchHeader0, add(0x20, 25)), 1) // change back
        }

        bytes[] memory chunks = new bytes[](1);
        bytes memory chunk0;

        // no block in chunk, revert
        chunk0 = new bytes(1);
        chunks[0] = chunk0;
        hevm.startPrank(address(0));
        hevm.expectRevert("no block in chunk");
        rollup.commitBatch(0, batchHeader0, chunks, new bytes(0), 0);
        hevm.stopPrank();

        // invalid chunk length, revert
        chunk0 = new bytes(1);
        chunk0[0] = bytes1(uint8(1)); // one block in this chunk
        chunks[0] = chunk0;
        hevm.startPrank(address(0));
        hevm.expectRevert("invalid chunk length");
        rollup.commitBatch(0, batchHeader0, chunks, new bytes(0), 0);
        hevm.stopPrank();

        // cannot skip last L1 message, revert
        chunk0 = new bytes(1 + 108);
        bytes memory bitmap = new bytes(32);
        chunk0[0] = bytes1(uint8(1)); // one block in this chunk
        chunk0[58] = bytes1(uint8(1)); // numTransactions = 1
        chunk0[60] = bytes1(uint8(1)); // numL1Messages = 1
        bitmap[31] = bytes1(uint8(1));
        chunks[0] = chunk0;
        hevm.startPrank(address(0));
        hevm.expectRevert("cannot skip last L1 message");
        rollup.commitBatch(0, batchHeader0, chunks, bitmap, 0);
        hevm.stopPrank();

        // num txs less than num L1 msgs, revert
        chunk0 = new bytes(1 + 108);
        bitmap = new bytes(32);
        chunk0[0] = bytes1(uint8(1)); // one block in this chunk
        chunk0[58] = bytes1(uint8(1)); // numTransactions = 1
        chunk0[60] = bytes1(uint8(3)); // numL1Messages = 3
        bitmap[31] = bytes1(uint8(3));
        chunks[0] = chunk0;
        hevm.startPrank(address(0));
        hevm.expectRevert("num txs less than num L1 msgs");
        rollup.commitBatch(0, batchHeader0, chunks, bitmap, 0);
        hevm.stopPrank();

        // incomplete l2 transaction data, revert
        chunk0 = new bytes(1 + 108 + 1);
        chunk0[0] = bytes1(uint8(1)); // one block in this chunk
        chunks[0] = chunk0;
        hevm.startPrank(address(0));
        hevm.expectRevert("incomplete l2 transaction data");
        rollup.commitBatch(0, batchHeader0, chunks, new bytes(0), 0);
        hevm.stopPrank();

        // commit batch with one chunk, no tx, correctly
        chunk0 = new bytes(1 + 108);
        assembly {
            mstore(add(chunk0, add(0x20, 77)), 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470)
        }
        chunk0[0] = bytes1(uint8(1)); // one block in this chunk
        chunks[0] = chunk0;
        hevm.startPrank(address(0));
        rollup.commitBatch(0, batchHeader0, chunks, new bytes(0), 0);
        hevm.stopPrank();
        assertGt(uint256(rollup.committedBatches(1)), 0);

        // batch is already committed, revert
        hevm.startPrank(address(0));
        hevm.expectRevert("batch already committed");
        rollup.commitBatch(0, batchHeader0, chunks, new bytes(0), 0);
        hevm.stopPrank();
    }

    function testFinalizeBatchWithProof() public {
        // caller not prover, revert
        hevm.expectRevert("caller not prover");
        rollup.finalizeBatchWithProof(new bytes(0), bytes32(0), bytes32(0), bytes32(0), new bytes(0));

        rollup.addProver(address(0));
        rollup.addSequencer(address(0));

        bytes memory batchHeader0 = new bytes(129);

        // import genesis batch
        assembly {
            mstore(add(batchHeader0, add(0x20, 25)), 1)
        }
        rollup.importGenesisBatch(batchHeader0, bytes32(uint256(1)));
        bytes32 batchHash0 = rollup.committedBatches(0);

        bytes[] memory chunks = new bytes[](1);
        bytes memory chunk0;

        // commit one batch
        chunk0 = new bytes(1 + 108);
        assembly {
            mstore(add(chunk0, add(0x20, 77)), 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470) // l1BlockRangeHash keccak256("")
        }
        chunk0[0] = bytes1(uint8(1)); // one block in this chunk
        chunks[0] = chunk0;
        hevm.startPrank(address(0));
        rollup.commitBatch(0, batchHeader0, chunks, new bytes(0), 0);
        hevm.stopPrank();
        assertGt(uint256(rollup.committedBatches(1)), 0);

        bytes memory batchHeader1 = new bytes(129);
        assembly {
            mstore(add(batchHeader1, 0x20), 0) // version
            mstore(add(batchHeader1, add(0x20, 1)), shl(192, 1)) // batchIndex
            mstore(add(batchHeader1, add(0x20, 9)), 0) // l1MessagePopped
            mstore(add(batchHeader1, add(0x20, 17)), 0) // totalL1MessagePopped
            mstore(add(batchHeader1, add(0x20, 25)), 0x17181f6abf48415097856d36591857cb134a3fe04b3aaf5e4ee8e82ec478f9cf) // dataHash
            mstore(add(batchHeader1, add(0x20, 57)), batchHash0) // parentBatchHash
            mstore(add(batchHeader1, add(0x20, 89)), 0) // lastAppliedL1Block
            mstore(add(batchHeader1, add(0x20, 97)), 0x10ca3eff73ebec87d2394fc58560afeab86dac7a21f5e402ea0a55e5c8a6758f) // blockRangeHash
        }

        // incorrect batch hash, revert
        batchHeader1[0] = bytes1(uint8(1)); // change version to 1
        hevm.startPrank(address(0));
        hevm.expectRevert("incorrect batch hash");
        rollup.finalizeBatchWithProof(batchHeader1, bytes32(uint256(1)), bytes32(uint256(2)), bytes32(0), new bytes(0));
        hevm.stopPrank();
        batchHeader1[0] = bytes1(uint8(0)); // change back

        // batch header length too small, revert
        hevm.startPrank(address(0));
        hevm.expectRevert("batch header length too small");
        rollup.finalizeBatchWithProof(
            new bytes(128),
            bytes32(uint256(1)),
            bytes32(uint256(2)),
            bytes32(0),
            new bytes(0)
        );
        hevm.stopPrank();

        // wrong bitmap length, revert
        hevm.startPrank(address(0));
        hevm.expectRevert("wrong bitmap length");
        rollup.finalizeBatchWithProof(
            new bytes(130),
            bytes32(uint256(1)),
            bytes32(uint256(2)),
            bytes32(0),
            new bytes(0)
        );
        hevm.stopPrank();

        // incorrect previous state root, revert
        hevm.startPrank(address(0));
        hevm.expectRevert("incorrect previous state root");
        rollup.finalizeBatchWithProof(batchHeader1, bytes32(uint256(2)), bytes32(uint256(2)), bytes32(0), new bytes(0));
        hevm.stopPrank();

        // verify success
        assertBoolEq(rollup.isBatchFinalized(1), false);
        hevm.startPrank(address(0));
        rollup.finalizeBatchWithProof(
            batchHeader1,
            bytes32(uint256(1)),
            bytes32(uint256(2)),
            bytes32(uint256(3)),
            new bytes(0)
        );
        hevm.stopPrank();
        assertBoolEq(rollup.isBatchFinalized(1), true);
        assertEq(rollup.finalizedStateRoots(1), bytes32(uint256(2)));
        assertEq(rollup.withdrawRoots(1), bytes32(uint256(3)));
        assertEq(rollup.lastFinalizedBatchIndex(), 1);

        // batch already verified, revert
        hevm.startPrank(address(0));
        hevm.expectRevert("batch already verified");
        rollup.finalizeBatchWithProof(
            batchHeader1,
            bytes32(uint256(1)),
            bytes32(uint256(2)),
            bytes32(uint256(3)),
            new bytes(0)
        );
        hevm.stopPrank();
    }

    function testCommitAndFinalizeWithL1Messages() public {
        rollup.addSequencer(address(0));
        rollup.addProver(address(0));

        hevm.roll(2);

        // import 300 L1 messages
        for (uint256 i = 0; i < 300; i++) {
            messageQueue.appendCrossDomainMessage(address(this), 1000000, new bytes(0));
        }

        // import genesis batch first
        bytes memory batchHeader0 = new bytes(129);
        assembly {
            mstore(add(batchHeader0, add(0x20, 25)), 1)
        }
        rollup.importGenesisBatch(batchHeader0, bytes32(uint256(1)));
        bytes32 batchHash0 = rollup.committedBatches(0);

        bytes memory bitmap;
        bytes[] memory chunks;
        bytes memory chunk0;
        bytes memory chunk1;

        // commit batch1, one chunk with one block, 1 tx, 1 L1 message, no skip
        // => payload for data hash of chunk0
        //   0000000000000000 - blockContext 0 - blockNumber
        //   0000000000000000 - blockContext 0 - timestamp
        //   0000000000000000000000000000000000000000000000000000000000000000 - blockContext 0 - baseFee
        //   0000000000000000 - blockContext 0 - gasLimit
        //   0001 - blockContext 0 - numTransactions
        //   0001 - blockContext 0 - numL1Messages
        //   0000000000000001 - blockContext 0 - lastAppliedL1Block
        //   a2277fd30bbbe74323309023b56035b376d7768ad237ae4fc46ead7dc9591ae1 - L1 Message Tx Hash
        //   0000000000000001 - chunk 0 - lastAppliedL1Block
        //   b10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf6 - chunk 0 - l1BlockRangeHash
        // => data hash for chunk0
        //   7cf07190f6882a8027e86d92f4b37e53f1c22867c58aa7db008d80a864aa7908
        // => data hash for all chunks
        //   86fcdd7b593809d108dae8a3a696e5ae4af774943f15cc2fd3c39cd02dabd0d7
        // => payload for batch header
        //   00
        //   0000000000000001
        //   0000000000000001
        //   0000000000000001
        //   86fcdd7b593809d108dae8a3a696e5ae4af774943f15cc2fd3c39cd02dabd0d7
        //   743dab51a4c73747185caad9effa81411a067f3d7aa69d69d4b7f3e9802a71c4
        //   0000000000000000000000000000000000000000000000000000000000000000
        //   0000000000000001
        //   b10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf6
        // => hash for batch header
        //   b6448e0bbd8226646f2099cd47160478768e5ccc32b486189073dfcedbad34e3
        bytes memory batchHeader1 = new bytes(129 + 32);
        assembly {
            mstore(add(batchHeader1, 0x20), 0) // version
            mstore(add(batchHeader1, add(0x20, 1)), shl(192, 1)) // batchIndex = 1
            mstore(add(batchHeader1, add(0x20, 9)), shl(192, 1)) // l1MessagePopped = 1
            mstore(add(batchHeader1, add(0x20, 17)), shl(192, 1)) // totalL1MessagePopped = 1
            mstore(add(batchHeader1, add(0x20, 25)), 0x86fcdd7b593809d108dae8a3a696e5ae4af774943f15cc2fd3c39cd02dabd0d7) // dataHash
            mstore(add(batchHeader1, add(0x20, 57)), batchHash0) // parentBatchHash
            mstore(add(batchHeader1, add(0x20, 89)), 0) // bitmap0
            mstore(add(batchHeader1, add(0x20, 121)), shl(192, 1)) // lastAppliedL1Block
            mstore(
                add(batchHeader1, add(0x20, 129)),
                0xb5d9d894133a730aa651ef62d26b0ffa846233c74177a591a4a896adfda97d22
            ) // blockRangeHash
        }
        chunk0 = new bytes(1 + 108);
        assembly {
            mstore(add(chunk0, 0x20), shl(248, 1)) // numBlocks = 1
            mstore(add(chunk0, add(0x21, 56)), shl(240, 1)) // numTransactions = 1, block 0
            mstore(add(chunk0, add(0x21, 58)), shl(240, 1)) // numL1Messages = 1, block 0
            mstore(add(chunk0, add(0x21, 60)), shl(192, 1)) // lastAppliedL1Block = 1, block 0
            mstore(add(chunk0, add(0x20, 69)), shl(192, 1)) // lastAppliedL1Block = 1, chunk 0
            mstore(add(chunk0, add(0x20, 77)), 0xb10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf6) // blockRangeHash
        }
        chunks = new bytes[](1);
        chunks[0] = chunk0;
        bitmap = new bytes(32);
        hevm.startPrank(address(0));
        hevm.expectEmit(true, true, false, true);
        emit CommitBatch(1, bytes32(0xb6448e0bbd8226646f2099cd47160478768e5ccc32b486189073dfcedbad34e3));
        rollup.commitBatch(0, batchHeader0, chunks, bitmap, 0);
        hevm.stopPrank();
        assertBoolEq(rollup.isBatchFinalized(1), false);
        bytes32 batchHash1 = rollup.committedBatches(1);
        assertEq(batchHash1, bytes32(0xb6448e0bbd8226646f2099cd47160478768e5ccc32b486189073dfcedbad34e3));

        // finalize batch1
        hevm.startPrank(address(0));
        hevm.expectEmit(true, true, false, true);
        emit FinalizeBatch(1, batchHash1, bytes32(uint256(2)), bytes32(uint256(3)));
        rollup.finalizeBatchWithProof(
            batchHeader1,
            bytes32(uint256(1)),
            bytes32(uint256(2)),
            bytes32(uint256(3)),
            new bytes(0)
        );
        hevm.stopPrank();
        assertBoolEq(rollup.isBatchFinalized(1), true);
        assertEq(rollup.finalizedStateRoots(1), bytes32(uint256(2)));
        assertEq(rollup.withdrawRoots(1), bytes32(uint256(3)));
        assertEq(rollup.lastFinalizedBatchIndex(), 1);
        assertBoolEq(messageQueue.isMessageSkipped(0), false);
        assertEq(messageQueue.pendingQueueIndex(), 1);

        // commit batch2 with two chunks, correctly
        // 1. chunk0 has one block, 3 tx, no L1 messages
        //   => payload for chunk0
        //    0000000000000000
        //    0000000000000000
        //    0000000000000000000000000000000000000000000000000000000000000000
        //    0000000000000000
        //    0003
        //    0000
        //    0000000000000001 - blockContext 0 - lastAppliedL1Block
        //    ... (some tx hashes)
        //    0000000000000001 - chunk 0 - lastAppliedL1Block
        //    b10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf6 - chunk 0 - l1BlockRangeHash
        //   => data hash for chunk0
        //    2ac1dad3f3696e5581dfc10f2c7a7a8fc5b344285f7d332c7895a8825fca609a
        // 2. chunk1 has three blocks
        //   2.1 block0 has 5 tx, 3 L1 messages, no skips
        //   2.2 block1 has 10 tx, 5 L1 messages, even is skipped, last is not skipped
        //   2.2 block1 has 300 tx, 256 L1 messages, odd position is skipped, last is not skipped
        //   => payload for chunk1
        //    0000000000000000
        //    0000000000000000
        //    0000000000000000000000000000000000000000000000000000000000000000
        //    0000000000000000
        //    0005
        //    0000000000000000
        //    0000000000000000
        //    0000000000000000000000000000000000000000000000000000000000000000
        //    0000000000000000
        //    000a
        //    0000000000000000
        //    0000000000000000
        //    0000000000000000000000000000000000000000000000000000000000000000
        //    0000000000000000
        //    012c
        //    ... (some tx hashes)
        //   => data hash for chunk2
        //    e1276f58354ab2372050bde30d8c970ccc3728c76e97f37deebeee83ecbf5705
        // => data hash for all chunks
        //   3de87c00834353063966bbb378e76de5956c1d15e8c218f907196f71426ebdec
        // => payload for batch header
        //  00
        //  0000000000000002
        //  0000000000000108
        //  0000000000000109
        //  3de87c00834353063966bbb378e76de5956c1d15e8c218f907196f71426ebdec
        //  cef70bf80683c4d9b8b2813e90c314e8c56648e231300b8cfed9d666b0caf14e
        //  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa800000000000000000000000000000000000000000000000000000000000000aa
        //  0000000000000001 - lastAppliedL1Block
        //  b10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf6 - l1BlockRangeHash
        // => hash for batch header
        //  86dd7e3d438fe6f08b4dc82dfb7fc4e025cd252d789d71a8a5865c5169e8d5df
        bytes memory batchHeader2 = new bytes(129 + 32 + 32);
        assembly {
            mstore(add(batchHeader2, 0x20), 0) // version
            mstore(add(batchHeader2, add(0x20, 1)), shl(192, 2)) // batchIndex = 2
            mstore(add(batchHeader2, add(0x20, 9)), shl(192, 264)) // l1MessagePopped = 264
            mstore(add(batchHeader2, add(0x20, 17)), shl(192, 265)) // totalL1MessagePopped = 265
            mstore(add(batchHeader2, add(0x20, 25)), 0x3de87c00834353063966bbb378e76de5956c1d15e8c218f907196f71426ebdec) // dataHash
            mstore(add(batchHeader2, add(0x20, 57)), batchHash1) // parentBatchHash
            mstore(
                add(batchHeader2, add(0x20, 89)),
                77194726158210796949047323339125271902179989777093709359638389338608753093160
            ) // bitmap0
            mstore(add(batchHeader2, add(0x20, 121)), 42) // bitmap1
            mstore(add(batchHeader2, add(0x20, 153)), shl(192, 1)) // lastAppliedL1Block = 1
            mstore(
                add(batchHeader2, add(0x20, 161)),
                0xad51961b5d4726f7c7501e5a50c32465739873a32d54b6c4fbb4f01c7263e6c0
            ) // blockRangeHash
        }
        chunk0 = new bytes(1 + 108 + 3 * 5);
        assembly {
            mstore(add(chunk0, 0x20), shl(248, 1)) // numBlocks = 1
            mstore(add(chunk0, add(0x21, 56)), shl(240, 3)) // numTransactions = 3
            mstore(add(chunk0, add(0x21, 58)), shl(240, 0)) // numL1Messages = 0
            mstore(add(chunk0, add(0x21, 60)), shl(192, 1)) // lastAppliedL1Block = 1, block 0
        }
        for (uint256 i = 0; i < 3; i++) {
            assembly {
                mstore(add(chunk0, add(101, mul(i, 5))), shl(224, 1)) // tx = "0x00"
            }
        }
        assembly {
            mstore(add(chunk0, 116), shl(192, 1)) // lastAppliedL1Block = 1, chunk 0
            mstore(add(chunk0, 124), 0xb10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf6) // l1BlockRangeHash, chunk 0
        }
        chunk1 = new bytes(1 + 68 * 3 + 51 * 5 + 40);
        assembly {
            mstore(add(chunk1, 0x20), shl(248, 3)) // numBlocks = 3
            mstore(add(chunk1, add(33, 56)), shl(240, 5)) // block0.numTransactions = 5
            mstore(add(chunk1, add(33, 58)), shl(240, 3)) // block0.numL1Messages = 3
            mstore(add(chunk1, add(33, 60)), shl(192, 1)) // lastAppliedL1Block = 1, block 0
            mstore(add(chunk1, add(101, 56)), shl(240, 10)) // block1.numTransactions = 10
            mstore(add(chunk1, add(101, 58)), shl(240, 5)) // block1.numL1Messages = 5
            mstore(add(chunk1, add(101, 60)), shl(192, 1)) // lastAppliedL1Block = 1, block 1
            mstore(add(chunk1, add(169, 56)), shl(240, 300)) // block1.numTransactions = 300
            mstore(add(chunk1, add(169, 58)), shl(240, 256)) // block1.numL1Messages = 256
            mstore(add(chunk1, add(169, 60)), shl(192, 1)) // lastAppliedL1Block = 1, block 2
        }
        for (uint256 i = 0; i < 51; i++) {
            assembly {
                mstore(add(chunk1, add(237, mul(i, 5))), shl(224, 1)) // tx = "0x00"
            }
        }
        assembly {
            mstore(add(chunk1, 492), shl(192, 1)) // lastAppliedL1Block = 1, chunk 1
            mstore(add(chunk1, 500), 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470) // l1BlockRangeHash, chunk 1
        }
        chunks = new bytes[](2);
        chunks[0] = chunk0;
        chunks[1] = chunk1;
        bitmap = new bytes(64);
        assembly {
            mstore(
                add(bitmap, add(0x20, 0)),
                77194726158210796949047323339125271902179989777093709359638389338608753093160
            ) // bitmap0
            mstore(add(bitmap, add(0x20, 32)), 42) // bitmap1
        }

        // too many txs in one chunk, revert
        rollup.updateMaxNumTxInChunk(2); // 3 - 1
        hevm.startPrank(address(0));
        hevm.expectRevert("too many txs in one chunk");
        rollup.commitBatch(0, batchHeader1, chunks, bitmap, 0); // first chunk with too many txs
        hevm.stopPrank();
        rollup.updateMaxNumTxInChunk(185); // 5+10+300 - 2 - 127
        hevm.startPrank(address(0));
        hevm.expectRevert("too many txs in one chunk");
        rollup.commitBatch(0, batchHeader1, chunks, bitmap, 0); // second chunk with too many txs
        hevm.stopPrank();

        rollup.updateMaxNumTxInChunk(186);
        hevm.startPrank(address(0));
        hevm.expectEmit(true, true, false, true);
        emit CommitBatch(2, bytes32(0x86dd7e3d438fe6f08b4dc82dfb7fc4e025cd252d789d71a8a5865c5169e8d5df));
        rollup.commitBatch(0, batchHeader1, chunks, bitmap, 0);
        hevm.stopPrank();
        assertBoolEq(rollup.isBatchFinalized(2), false);
        bytes32 batchHash2 = rollup.committedBatches(2);
        assertEq(batchHash2, bytes32(0x86dd7e3d438fe6f08b4dc82dfb7fc4e025cd252d789d71a8a5865c5169e8d5df));

        // verify committed batch correctly
        hevm.startPrank(address(0));
        hevm.expectEmit(true, true, false, true);
        emit FinalizeBatch(2, batchHash2, bytes32(uint256(4)), bytes32(uint256(5)));
        rollup.finalizeBatchWithProof(
            batchHeader2,
            bytes32(uint256(2)),
            bytes32(uint256(4)),
            bytes32(uint256(5)),
            new bytes(0)
        );
        hevm.stopPrank();
        assertBoolEq(rollup.isBatchFinalized(2), true);
        assertEq(rollup.finalizedStateRoots(2), bytes32(uint256(4)));
        assertEq(rollup.withdrawRoots(2), bytes32(uint256(5)));
        assertEq(rollup.lastFinalizedBatchIndex(), 2);
        assertEq(messageQueue.pendingQueueIndex(), 265);
        // 1 ~ 4, zero
        for (uint256 i = 1; i < 4; i++) {
            assertBoolEq(messageQueue.isMessageSkipped(i), false);
        }
        // 4 ~ 9, even is nonzero, odd is zero
        for (uint256 i = 4; i < 9; i++) {
            if (i % 2 == 1 || i == 8) {
                assertBoolEq(messageQueue.isMessageSkipped(i), false);
            } else {
                assertBoolEq(messageQueue.isMessageSkipped(i), true);
            }
        }
        // 9 ~ 265, even is nonzero, odd is zero
        for (uint256 i = 9; i < 265; i++) {
            if (i % 2 == 1 || i == 264) {
                assertBoolEq(messageQueue.isMessageSkipped(i), false);
            } else {
                assertBoolEq(messageQueue.isMessageSkipped(i), true);
            }
        }
    }

    function testRevertBatch() public {
        // caller not owner, revert
        hevm.startPrank(address(1));
        hevm.expectRevert("Ownable: caller is not the owner");
        rollup.revertBatch(new bytes(129), 1);
        hevm.stopPrank();

        rollup.addSequencer(address(0));

        bytes memory batchHeader0 = new bytes(129);

        // import genesis batch
        assembly {
            mstore(add(batchHeader0, add(0x20, 25)), 1)
        }
        rollup.importGenesisBatch(batchHeader0, bytes32(uint256(1)));
        bytes32 batchHash0 = rollup.committedBatches(0);

        bytes[] memory chunks = new bytes[](1);
        bytes memory chunk0;

        // commit one batch
        chunk0 = new bytes(1 + 108);
        assembly {
            mstore(add(chunk0, add(0x20, 77)), 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470) // l1BlockRangeHash keccak256("")
        }
        chunk0[0] = bytes1(uint8(1)); // one block in this chunk
        chunks[0] = chunk0;
        hevm.startPrank(address(0));
        rollup.commitBatch(0, batchHeader0, chunks, new bytes(0), 0);
        hevm.stopPrank();

        bytes memory batchHeader1 = new bytes(129);
        assembly {
            mstore(add(batchHeader1, 0x20), 0) // version
            mstore(add(batchHeader1, add(0x20, 1)), shl(192, 1)) // batchIndex
            mstore(add(batchHeader1, add(0x20, 9)), 0) // l1MessagePopped
            mstore(add(batchHeader1, add(0x20, 17)), 0) // totalL1MessagePopped
            mstore(add(batchHeader1, add(0x20, 25)), 0x17181f6abf48415097856d36591857cb134a3fe04b3aaf5e4ee8e82ec478f9cf) // dataHash
            mstore(add(batchHeader1, add(0x20, 57)), batchHash0) // parentBatchHash
            mstore(add(batchHeader1, add(0x20, 89)), 0) // lastAppliedL1Block
            mstore(add(batchHeader1, add(0x20, 97)), 0x10ca3eff73ebec87d2394fc58560afeab86dac7a21f5e402ea0a55e5c8a6758f) // blockRangeHash
        }

        // commit another batch
        hevm.startPrank(address(0));
        rollup.commitBatch(0, batchHeader1, chunks, new bytes(0), 0);
        hevm.stopPrank();

        // count must be nonzero, revert
        hevm.expectRevert("count must be nonzero");
        rollup.revertBatch(batchHeader0, 0);

        // incorrect batch hash, revert
        hevm.expectRevert("incorrect batch hash");
        batchHeader1[0] = bytes1(uint8(1)); // change version to 1
        rollup.revertBatch(batchHeader1, 1);
        batchHeader1[0] = bytes1(uint8(0)); // change back

        // revert middle batch, revert
        hevm.expectRevert("reverting must start from the ending");
        rollup.revertBatch(batchHeader1, 1);

        // can only revert unfinalized batch, revert
        hevm.expectRevert("can only revert unfinalized batch");
        rollup.revertBatch(batchHeader0, 3);

        // succeed to revert next two pending batches.

        hevm.expectEmit(true, true, false, true);
        emit RevertBatch(1, rollup.committedBatches(1));
        hevm.expectEmit(true, true, false, true);
        emit RevertBatch(2, rollup.committedBatches(2));

        assertGt(uint256(rollup.committedBatches(1)), 0);
        assertGt(uint256(rollup.committedBatches(2)), 0);
        rollup.revertBatch(batchHeader1, 2);
        assertEq(uint256(rollup.committedBatches(1)), 0);
        assertEq(uint256(rollup.committedBatches(2)), 0);
    }

    function testAddAndRemoveSequencer(address _sequencer) public {
        // set by non-owner, should revert
        hevm.startPrank(address(1));
        hevm.expectRevert("Ownable: caller is not the owner");
        rollup.addSequencer(_sequencer);
        hevm.expectRevert("Ownable: caller is not the owner");
        rollup.removeSequencer(_sequencer);
        hevm.stopPrank();

        hevm.expectRevert("not EOA");
        rollup.addSequencer(address(this));
        hevm.assume(_sequencer.code.length == 0);

        // change to random EOA operator
        hevm.expectEmit(true, false, false, true);
        emit UpdateSequencer(_sequencer, true);

        assertBoolEq(rollup.isSequencer(_sequencer), false);
        rollup.addSequencer(_sequencer);
        assertBoolEq(rollup.isSequencer(_sequencer), true);

        hevm.expectEmit(true, false, false, true);
        emit UpdateSequencer(_sequencer, false);
        rollup.removeSequencer(_sequencer);
        assertBoolEq(rollup.isSequencer(_sequencer), false);
    }

    // commit batch, 10 chunks, many txs, many L1 messages, many l1 block hashes
    function testCommitBatchWithManyL1BlockHashesTxs() public {
        bytes[] memory chunks = new bytes[](10);
        bytes memory chunk;

        for (uint256 i = 0; i < 300; i++) {
            messageQueue.appendCrossDomainMessage(address(this), 1000000, new bytes(0));
        }

        rollup.addSequencer(address(0));
        rollup.addProver(address(0));

        // import genesis batch first
        bytes memory batchHeader0 = new bytes(129);
        assembly {
            mstore(add(batchHeader0, add(0x20, 25)), 1)
        }
        rollup.importGenesisBatch(batchHeader0, bytes32(uint256(1)));
        bytes32 batchHash0 = rollup.committedBatches(0);

        bytes memory batchHeader1 = new bytes(129 + 32);
        assembly {
            mstore(add(batchHeader1, 0x20), 0) // version
            mstore(add(batchHeader1, add(0x20, 1)), shl(192, 1)) // batchIndex = 1
            mstore(add(batchHeader1, add(0x20, 9)), shl(192, 162)) // l1MessagePopped = 162
            mstore(add(batchHeader1, add(0x20, 17)), shl(192, 162)) // totalL1MessagePopped = 162
            mstore(add(batchHeader1, add(0x20, 25)), 0x7b57de313b5f6add99c3c80246deb99fbdda3735a95e4fb2dded72c874d0c116) // dataHash
            mstore(add(batchHeader1, add(0x20, 57)), batchHash0) // parentBatchHash
            mstore(add(batchHeader1, add(0x20, 89)), 0) // bitmap0
            mstore(add(batchHeader1, add(0x20, 121)), shl(192, 0x8A)) // lastAppliedL1Block
            mstore(
                add(batchHeader1, add(0x20, 129)),
                0xa8cf448633ba639062b57859aec34b05e57c0f4774451fba0aba365865c785e2
            ) // blockRangeHash
        }

        uint256 chunkPtr;
        uint256 blockPtr;
        uint256 offsetPtr;

        // Chunk 1
        chunk = new bytes(
            1 +
                40 +
                3 *
                68 + // 3 blocks
                19 *
                4 +
                19 *
                512 // 19 not L1 Msg Tx
        );

        assembly {
            chunkPtr := add(chunk, 0x20)
            blockPtr := add(chunk, add(0x20, 1))

            mstore(chunkPtr, shl(248, 3)) // numBlocks = 3
        }

        assembly {
            offsetPtr := add(blockPtr, 56)
            mstore(offsetPtr, shl(240, 7)) // numTransactions = 7
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(240, 3)) // numL1Messages = 3
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(192, 0x77)) // lastAppliedL1Block
        }

        assembly {
            blockPtr := add(offsetPtr, 8)
            offsetPtr := add(blockPtr, 56)

            mstore(offsetPtr, shl(240, 9)) // numTransactions = 9
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(240, 2)) // numL1Messages = 2
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(192, 0x77)) // lastAppliedL1Block
        }

        assembly {
            blockPtr := add(offsetPtr, 8)
            offsetPtr := add(blockPtr, 56)

            mstore(offsetPtr, shl(240, 13)) // numTransactions = 13
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(240, 5)) // numL1Messages = 5
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(192, 0x77)) // lastAppliedL1Block
        }

        assembly {
            offsetPtr := add(offsetPtr, 8)

            let i := 0
            for {

            } lt(i, 19) {

            } {
                mstore(offsetPtr, shl(224, 512)) // 4 bites size of 512 bytes Tx Payload
                offsetPtr := add(offsetPtr, 516) // 4 bytes size + 512 bytes Tx Payload
                i := add(i, 1)
            }

            mstore(offsetPtr, shl(192, 0x77)) // lastAppliedL1Block in chunk
            offsetPtr := add(offsetPtr, 8)
            mstore(offsetPtr, 0xa8cf448633ba639062b57859aec34b05e57c0f4774451fba0aba365865c785e2) // l1 block range hash in chunk
        }

        chunks[0] = chunk;

        // Chunk 2
        chunk = new bytes(
            1 +
                40 +
                8 *
                68 + // 8 blocks
                44 *
                4 +
                44 *
                512 // 40 not L1 Msg Tx
        );

        assembly {
            chunkPtr := add(chunk, 0x20)
            blockPtr := add(chunk, add(0x20, 1))

            mstore(chunkPtr, shl(248, 8)) // numBlocks = 8
        }

        assembly {
            offsetPtr := add(blockPtr, 56)
            mstore(offsetPtr, shl(240, 22)) // numTransactions = 22
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(240, 10)) // numL1Messages = 10
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(192, 0x78)) // lastAppliedL1Block
        }

        assembly {
            blockPtr := add(offsetPtr, 8)
            offsetPtr := add(blockPtr, 56)

            mstore(offsetPtr, shl(240, 5)) // numTransactions = 5
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(240, 1)) // numL1Messages = 1
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(192, 0x78)) // lastAppliedL1Block
        }

        assembly {
            blockPtr := add(offsetPtr, 8)
            offsetPtr := add(blockPtr, 56)

            mstore(offsetPtr, shl(240, 15)) // numTransactions = 15
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(240, 9)) // numL1Messages = 9
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(192, 0x78)) // lastAppliedL1Block
        }

        assembly {
            blockPtr := add(offsetPtr, 8)
            offsetPtr := add(blockPtr, 56)

            mstore(offsetPtr, shl(240, 5)) // numTransactions = 5
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(240, 3)) // numL1Messages = 3
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(192, 0x78)) // lastAppliedL1Block
        }

        assembly {
            blockPtr := add(offsetPtr, 8)
            offsetPtr := add(blockPtr, 56)

            mstore(offsetPtr, shl(240, 12)) // numTransactions = 12
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(240, 12)) // numL1Messages = 12
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(192, 0x78)) // lastAppliedL1Block
        }

        assembly {
            blockPtr := add(offsetPtr, 8)
            offsetPtr := add(blockPtr, 56)

            mstore(offsetPtr, shl(240, 11)) // numTransactions = 11
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(240, 5)) // numL1Messages = 5
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(192, 0x7A)) // lastAppliedL1Block
        }

        assembly {
            blockPtr := add(offsetPtr, 8)
            offsetPtr := add(blockPtr, 56)

            mstore(offsetPtr, shl(240, 12)) // numTransactions = 12
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(240, 5)) // numL1Messages = 5
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(192, 0x7A)) // lastAppliedL1Block
        }

        assembly {
            blockPtr := add(offsetPtr, 8)
            offsetPtr := add(blockPtr, 56)

            mstore(offsetPtr, shl(240, 12)) // numTransactions = 12
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(240, 5)) // numL1Messages = 5
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(192, 0x7B)) // lastAppliedL1Block
        }

        assembly {
            offsetPtr := add(offsetPtr, 8)

            let i := 0
            for {

            } lt(i, 44) {

            } {
                // 44 Txs
                mstore(offsetPtr, shl(224, 512)) // 4 bites size of 512 bytes Tx Payload
                offsetPtr := add(offsetPtr, 516) // 4 bytes size + 512 bytes Tx Payload
                i := add(i, 1)
            }

            mstore(offsetPtr, shl(192, 0x7B)) // lastAppliedL1Block in chunk
            offsetPtr := add(offsetPtr, 8)
            mstore(offsetPtr, 0x092406e276c3b811614283ada503db6bf86fe8e4771920d1691301213c60ad27) // l1 block range hash in chunk
        }

        chunks[1] = chunk;

        // Chunk 3
        chunk = new bytes(
            1 +
                40 +
                2 *
                68 + // 2 blocks
                13 *
                4 +
                13 *
                512 // 13 not L1 Msg Tx
        );

        assembly {
            chunkPtr := add(chunk, 0x20)
            blockPtr := add(chunk, add(0x20, 1))

            mstore(chunkPtr, shl(248, 2)) // numBlocks = 2
        }

        assembly {
            offsetPtr := add(blockPtr, 56)
            mstore(offsetPtr, shl(240, 19)) // numTransactions = 19
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(240, 10)) // numL1Messages = 10
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(192, 0x7B)) // lastAppliedL1Block
        }

        assembly {
            blockPtr := add(offsetPtr, 8)
            offsetPtr := add(blockPtr, 56)

            mstore(offsetPtr, shl(240, 5)) // numTransactions = 5
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(240, 1)) // numL1Messages = 1
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(192, 0x7C)) // lastAppliedL1Block
        }

        assembly {
            offsetPtr := add(offsetPtr, 8)

            let i := 0
            for {

            } lt(i, 13) {

            } {
                // 13 Txs
                mstore(offsetPtr, shl(224, 512)) // 4 bites size of 512 bytes Tx Payload
                offsetPtr := add(offsetPtr, 516) // 4 bytes size + 512 bytes Tx Payload
                i := add(i, 1)
            }

            mstore(offsetPtr, shl(192, 0x7C)) // lastAppliedL1Block in chunk
            offsetPtr := add(offsetPtr, 8)
            mstore(offsetPtr, 0xfd65998deda42723bb9b4108c7a015c3ce1c178917dd7c235dec2d68de3e73dd) // l1 block range hash in chunk
        }

        chunks[2] = chunk;

        // Chunk 4
        chunk = new bytes(
            1 +
                40 +
                3 *
                68 + // 3 blocks
                20 *
                4 +
                20 *
                512 // 20 not L1 Msg Tx
        );

        assembly {
            chunkPtr := add(chunk, 0x20)
            blockPtr := add(chunk, add(0x20, 1))

            mstore(chunkPtr, shl(248, 3)) // numBlocks = 3
        }

        assembly {
            offsetPtr := add(blockPtr, 56)
            mstore(offsetPtr, shl(240, 12)) // numTransactions = 12
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(240, 2)) // numL1Messages = 2
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(192, 0x7C)) // lastAppliedL1Block
        }

        assembly {
            blockPtr := add(offsetPtr, 8)
            offsetPtr := add(blockPtr, 56)

            mstore(offsetPtr, shl(240, 7)) // numTransactions = 7
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(240, 2)) // numL1Messages = 2
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(192, 0x7D)) // lastAppliedL1Block
        }

        assembly {
            blockPtr := add(offsetPtr, 8)
            offsetPtr := add(blockPtr, 56)

            mstore(offsetPtr, shl(240, 7)) // numTransactions = 7
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(240, 2)) // numL1Messages = 2
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(192, 0x7D)) // lastAppliedL1Block
        }

        assembly {
            offsetPtr := add(offsetPtr, 8)

            let i := 0
            for {

            } lt(i, 20) {

            } {
                // 20 Txs
                mstore(offsetPtr, shl(224, 512)) // 4 bites size of 512 bytes Tx Payload
                offsetPtr := add(offsetPtr, 516) // 4 bytes size + 512 bytes Tx Payload
                i := add(i, 1)
            }

            mstore(offsetPtr, shl(192, 0x7D)) // lastAppliedL1Block in chunk
            offsetPtr := add(offsetPtr, 8)
            mstore(offsetPtr, 0x39e5371562db15cae477e227498ea2b8caecdd60d087341449f8b46a102f0af7) // l1 block range hash in chunk
        }

        chunks[3] = chunk;

        // Chunk 5
        chunk = new bytes(
            1 +
                40 +
                2 *
                68 + // 2 blocks
                12 *
                4 +
                12 *
                512 // 12 not L1 Msg Tx
        );

        assembly {
            chunkPtr := add(chunk, 0x20)
            blockPtr := add(chunk, add(0x20, 1))

            mstore(chunkPtr, shl(248, 2)) // numBlocks = 2
        }

        assembly {
            offsetPtr := add(blockPtr, 56)
            mstore(offsetPtr, shl(240, 8)) // numTransactions = 8
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(240, 2)) // numL1Messages = 2
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(192, 0x7E)) // lastAppliedL1Block
        }

        assembly {
            blockPtr := add(offsetPtr, 8)
            offsetPtr := add(blockPtr, 56)

            mstore(offsetPtr, shl(240, 8)) // numTransactions = 8
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(240, 2)) // numL1Messages = 2
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(192, 0x7E)) // lastAppliedL1Block
        }

        assembly {
            offsetPtr := add(offsetPtr, 8)

            let i := 0
            for {

            } lt(i, 12) {

            } {
                // 20 Txs
                mstore(offsetPtr, shl(224, 512)) // 4 bites size of 512 bytes Tx Payload
                offsetPtr := add(offsetPtr, 516) // 4 bytes size + 512 bytes Tx Payload
                i := add(i, 1)
            }

            mstore(offsetPtr, shl(192, 0x7E)) // lastAppliedL1Block in chunk
            offsetPtr := add(offsetPtr, 8)
            mstore(offsetPtr, 0x3a20462b836d7e6b2754037a9f47405d03eb3e3c7af98c0b3b05c4d64542bb45) // l1 block range hash in chunk
        }

        chunks[4] = chunk;

        // Chunk 6
        chunk = new bytes(
            1 +
                40 +
                3 *
                68 + // 3 blocks
                19 *
                4 +
                19 *
                512 // 19 not L1 Msg Tx
        );

        assembly {
            chunkPtr := add(chunk, 0x20)
            blockPtr := add(chunk, add(0x20, 1))

            mstore(chunkPtr, shl(248, 3)) // numBlocks = 3
        }

        assembly {
            offsetPtr := add(blockPtr, 56)
            mstore(offsetPtr, shl(240, 7)) // numTransactions = 7
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(240, 3)) // numL1Messages = 3
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(192, 0x7F)) // lastAppliedL1Block
        }

        assembly {
            blockPtr := add(offsetPtr, 8)
            offsetPtr := add(blockPtr, 56)

            mstore(offsetPtr, shl(240, 9)) // numTransactions = 9
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(240, 2)) // numL1Messages = 2
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(192, 0x7F)) // lastAppliedL1Block
        }

        assembly {
            blockPtr := add(offsetPtr, 8)
            offsetPtr := add(blockPtr, 56)

            mstore(offsetPtr, shl(240, 13)) // numTransactions = 13
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(240, 5)) // numL1Messages = 5
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(192, 0x80)) // lastAppliedL1Block
        }

        assembly {
            offsetPtr := add(offsetPtr, 8)

            let i := 0
            for {

            } lt(i, 19) {

            } {
                mstore(offsetPtr, shl(224, 512)) // 4 bites size of 512 bytes Tx Payload
                offsetPtr := add(offsetPtr, 516) // 4 bytes size + 512 bytes Tx Payload
                i := add(i, 1)
            }

            mstore(offsetPtr, shl(192, 0x80)) // lastAppliedL1Block in chunk
            offsetPtr := add(offsetPtr, 8)
            mstore(offsetPtr, 0xff733928d2850747c2af8eeda384b947ced90ba76058a78bec5f6966d34b263c) // l1 block range hash in chunk
        }

        chunks[5] = chunk;

        // Chunk 7
        chunk = new bytes(
            1 +
                40 +
                8 *
                68 + // 8 blocks
                44 *
                4 +
                44 *
                512 // 40 not L1 Msg Tx
        );

        assembly {
            chunkPtr := add(chunk, 0x20)
            blockPtr := add(chunk, add(0x20, 1))

            mstore(chunkPtr, shl(248, 8)) // numBlocks = 8
        }

        assembly {
            offsetPtr := add(blockPtr, 56)
            mstore(offsetPtr, shl(240, 22)) // numTransactions = 22
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(240, 10)) // numL1Messages = 10
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(192, 0x80)) // lastAppliedL1Block
        }

        assembly {
            blockPtr := add(offsetPtr, 8)
            offsetPtr := add(blockPtr, 56)

            mstore(offsetPtr, shl(240, 5)) // numTransactions = 5
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(240, 1)) // numL1Messages = 1
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(192, 0x80)) // lastAppliedL1Block
        }

        assembly {
            blockPtr := add(offsetPtr, 8)
            offsetPtr := add(blockPtr, 56)

            mstore(offsetPtr, shl(240, 15)) // numTransactions = 15
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(240, 9)) // numL1Messages = 9
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(192, 0x82)) // lastAppliedL1Block
        }

        assembly {
            blockPtr := add(offsetPtr, 8)
            offsetPtr := add(blockPtr, 56)

            mstore(offsetPtr, shl(240, 5)) // numTransactions = 5
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(240, 3)) // numL1Messages = 3
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(192, 0x82)) // lastAppliedL1Block
        }

        assembly {
            blockPtr := add(offsetPtr, 8)
            offsetPtr := add(blockPtr, 56)

            mstore(offsetPtr, shl(240, 12)) // numTransactions = 12
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(240, 12)) // numL1Messages = 12
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(192, 0x83)) // lastAppliedL1Block
        }

        assembly {
            blockPtr := add(offsetPtr, 8)
            offsetPtr := add(blockPtr, 56)

            mstore(offsetPtr, shl(240, 11)) // numTransactions = 11
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(240, 5)) // numL1Messages = 5
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(192, 0x83)) // lastAppliedL1Block
        }

        assembly {
            blockPtr := add(offsetPtr, 8)
            offsetPtr := add(blockPtr, 56)

            mstore(offsetPtr, shl(240, 12)) // numTransactions = 12
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(240, 5)) // numL1Messages = 5
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(192, 0x83)) // lastAppliedL1Block
        }

        assembly {
            blockPtr := add(offsetPtr, 8)
            offsetPtr := add(blockPtr, 56)

            mstore(offsetPtr, shl(240, 12)) // numTransactions = 12
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(240, 5)) // numL1Messages = 5
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(192, 0x84)) // lastAppliedL1Block
        }

        assembly {
            offsetPtr := add(offsetPtr, 8)

            let i := 0
            for {

            } lt(i, 44) {

            } {
                // 44 Txs
                mstore(offsetPtr, shl(224, 512)) // 4 bites size of 512 bytes Tx Payload
                offsetPtr := add(offsetPtr, 516) // 4 bytes size + 512 bytes Tx Payload
                i := add(i, 1)
            }

            mstore(offsetPtr, shl(192, 0x84)) // lastAppliedL1Block in chunk
            offsetPtr := add(offsetPtr, 8)
            mstore(offsetPtr, 0xd499ae9fd9156c709dba0db48923020966a142d871cbe6c4844227783614d9a3) // l1 block range hash in chunk
        }

        chunks[6] = chunk;

        // Chunk 8
        chunk = new bytes(
            1 +
                40 +
                2 *
                68 + // 2 blocks
                13 *
                4 +
                13 *
                512 // 13 not L1 Msg Tx
        );

        assembly {
            chunkPtr := add(chunk, 0x20)
            blockPtr := add(chunk, add(0x20, 1))

            mstore(chunkPtr, shl(248, 2)) // numBlocks = 2
        }

        assembly {
            offsetPtr := add(blockPtr, 56)
            mstore(offsetPtr, shl(240, 19)) // numTransactions = 19
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(240, 10)) // numL1Messages = 10
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(192, 0x85)) // lastAppliedL1Block
        }

        assembly {
            blockPtr := add(offsetPtr, 8)
            offsetPtr := add(blockPtr, 56)

            mstore(offsetPtr, shl(240, 5)) // numTransactions = 5
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(240, 1)) // numL1Messages = 1
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(192, 0x85)) // lastAppliedL1Block
        }

        assembly {
            offsetPtr := add(offsetPtr, 8)

            let i := 0
            for {

            } lt(i, 13) {

            } {
                // 13 Txs
                mstore(offsetPtr, shl(224, 512)) // 4 bites size of 512 bytes Tx Payload
                offsetPtr := add(offsetPtr, 516) // 4 bytes size + 512 bytes Tx Payload
                i := add(i, 1)
            }

            mstore(offsetPtr, shl(192, 0x85)) // lastAppliedL1Block in chunk
            offsetPtr := add(offsetPtr, 8)
            mstore(offsetPtr, 0x9cbf2ce36946ee52114304e2dc20af020d6c27d837e20277f1ce8a6e3019a75b) // l1 block range hash in chunk
        }

        chunks[7] = chunk;

        // Chunk 9
        chunk = new bytes(
            1 +
                40 +
                3 *
                68 + // 3 blocks
                20 *
                4 +
                20 *
                512 // 20 not L1 Msg Tx
        );

        assembly {
            chunkPtr := add(chunk, 0x20)
            blockPtr := add(chunk, add(0x20, 1))

            mstore(chunkPtr, shl(248, 3)) // numBlocks = 3
        }

        assembly {
            offsetPtr := add(blockPtr, 56)
            mstore(offsetPtr, shl(240, 12)) // numTransactions = 12
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(240, 2)) // numL1Messages = 2
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(192, 0x85)) // lastAppliedL1Block
        }

        assembly {
            blockPtr := add(offsetPtr, 8)
            offsetPtr := add(blockPtr, 56)

            mstore(offsetPtr, shl(240, 7)) // numTransactions = 7
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(240, 2)) // numL1Messages = 2
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(192, 0x85)) // lastAppliedL1Block
        }

        assembly {
            blockPtr := add(offsetPtr, 8)
            offsetPtr := add(blockPtr, 56)

            mstore(offsetPtr, shl(240, 7)) // numTransactions = 7
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(240, 2)) // numL1Messages = 2
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(192, 0x86)) // lastAppliedL1Block
        }

        assembly {
            offsetPtr := add(offsetPtr, 8)

            let i := 0
            for {

            } lt(i, 20) {

            } {
                // 20 Txs
                mstore(offsetPtr, shl(224, 512)) // 4 bites size of 512 bytes Tx Payload
                offsetPtr := add(offsetPtr, 516) // 4 bytes size + 512 bytes Tx Payload
                i := add(i, 1)
            }

            mstore(offsetPtr, shl(192, 0x86)) // lastAppliedL1Block in chunk
            offsetPtr := add(offsetPtr, 8)
            mstore(offsetPtr, 0x638ec9231242321da81ceaa230e9df6e1f9fa53213076d45bf4b9ba16b1c5d22) // l1 block range hash in chunk
        }

        chunks[8] = chunk;

        // Chunk 10
        chunk = new bytes(
            1 +
                40 +
                2 *
                68 + // 2 blocks
                12 *
                4 +
                12 *
                512 // 12 not L1 Msg Tx
        );

        assembly {
            chunkPtr := add(chunk, 0x20)
            blockPtr := add(chunk, add(0x20, 1))

            mstore(chunkPtr, shl(248, 2)) // numBlocks = 2
        }

        assembly {
            offsetPtr := add(blockPtr, 56)
            mstore(offsetPtr, shl(240, 8)) // numTransactions = 8
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(240, 2)) // numL1Messages = 2
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(192, 0x87)) // lastAppliedL1Block
        }

        assembly {
            blockPtr := add(offsetPtr, 8)
            offsetPtr := add(blockPtr, 56)

            mstore(offsetPtr, shl(240, 8)) // numTransactions = 8
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(240, 2)) // numL1Messages = 2
            offsetPtr := add(offsetPtr, 2)
            mstore(offsetPtr, shl(192, 0x8A)) // lastAppliedL1Block
        }

        assembly {
            offsetPtr := add(offsetPtr, 8)

            let i := 0
            for {

            } lt(i, 12) {

            } {
                // 20 Txs
                mstore(offsetPtr, shl(224, 512)) // 4 bites size of 512 bytes Tx Payload
                offsetPtr := add(offsetPtr, 516) // 4 bytes size + 512 bytes Tx Payload
                i := add(i, 1)
            }

            mstore(offsetPtr, shl(192, 0x8A)) // lastAppliedL1Block in chunk
            offsetPtr := add(offsetPtr, 8)
            mstore(offsetPtr, 0x9791787170769e70bc0ddac0baeb9991a547873255a58d4bb0223b7437ecb22b) // l1 block range hash in chunk
        }

        chunks[9] = chunk;

        hevm.roll(250);
        hevm.startPrank(address(0));
        startMeasuringGas("commitBatch");
        rollup.commitBatch(0, batchHeader0, chunks, new bytes(32), 118);
        stopMeasuringGas();
        hevm.stopPrank();
        assertGt(uint256(rollup.committedBatches(1)), 0);

        hevm.startPrank(address(0));
        startMeasuringGas("finalizeBatchWithProof");
        rollup.finalizeBatchWithProof(
            batchHeader1,
            bytes32(uint256(1)),
            bytes32(uint256(2)),
            bytes32(uint256(3)),
            new bytes(0)
        );
        stopMeasuringGas();
        hevm.stopPrank();
    }

    // commit batch, one chunk with one block, 1 tx, 1 L1 message, no skip, 1 block hash range
    function testCommitBatchOneBlockHash() public {
        rollup.addSequencer(address(0));
        rollup.addProver(address(0));

        // Roll 256 blocks
        hevm.roll(256);

        // import 300 L1 messages
        for (uint256 i = 0; i < 300; i++) {
            messageQueue.appendCrossDomainMessage(address(this), 1000000, new bytes(0));
        }

        // import genesis batch first
        bytes memory batchHeader0 = new bytes(129);
        assembly {
            mstore(add(batchHeader0, add(0x20, 25)), 1)
        }
        rollup.importGenesisBatch(batchHeader0, bytes32(uint256(1)));
        bytes32 batchHash0 = rollup.committedBatches(0);

        bytes memory bitmap;
        // have only one chunk
        bytes memory chunk0;

        // commit batch1, one chunk with one block, 1 tx, 1 L1 message, no skip
        // => payload for data hash of chunk0
        //   0000000000000000 - blockNumber
        //   0000000000000000 - timestamp
        //   0000000000000000000000000000000000000000000000000000000000000000 - baseFee
        //   0000000000000000 - gasLimit
        //   0001 - numTransactions
        //   0001- numL1Messages
        //   0000000000000001 - lastAppliedL1Block
        //   a2277fd30bbbe74323309023b56035b376d7768ad237ae4fc46ead7dc9591ae1 - L1 Message Tx Hash
        //   0000000000000001 - chunk 0 - lastAppliedL1Block
        //   b10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf6 - chunk 0 - l1BlockRangeHash
        // => data hash for all chunks
        //   86fcdd7b593809d108dae8a3a696e5ae4af774943f15cc2fd3c39cd02dabd0d7
        // => payload for batch header
        //   00
        //   0000000000000001
        //   0000000000000001
        //   0000000000000001
        //   86fcdd7b593809d108dae8a3a696e5ae4af774943f15cc2fd3c39cd02dabd0d7
        //   743dab51a4c73747185caad9effa81411a067f3d7aa69d69d4b7f3e9802a71c4
        //   0000000000000000000000000000000000000000000000000000000000000000
        //   0000000000000001
        //   b5d9d894133a730aa651ef62d26b0ffa846233c74177a591a4a896adfda97d22
        // => hash for batch header
        //   b6448e0bbd8226646f2099cd47160478768e5ccc32b486189073dfcedbad34e3
        bytes memory batchHeader1 = new bytes(129 + 32);
        assembly {
            mstore(add(batchHeader1, 0x20), 0) // version
            mstore(add(batchHeader1, add(0x20, 1)), shl(192, 1)) // batchIndex = 1
            mstore(add(batchHeader1, add(0x20, 9)), shl(192, 1)) // l1MessagePopped = 1
            mstore(add(batchHeader1, add(0x20, 17)), shl(192, 1)) // totalL1MessagePopped = 1
            mstore(add(batchHeader1, add(0x20, 25)), 0x86fcdd7b593809d108dae8a3a696e5ae4af774943f15cc2fd3c39cd02dabd0d7) // dataHash
            mstore(add(batchHeader1, add(0x20, 57)), batchHash0) // parentBatchHash
            mstore(add(batchHeader1, add(0x20, 89)), 0) // bitmap0
            mstore(add(batchHeader1, add(0x20, 121)), shl(192, 1)) // lastAppliedL1Block
            mstore(
                add(batchHeader1, add(0x20, 129)),
                0xb5d9d894133a730aa651ef62d26b0ffa846233c74177a591a4a896adfda97d22
            ) // blockRangeHash
        }

        // set chunk data
        chunk0 = new bytes(1 + 108);
        assembly {
            mstore(add(chunk0, 0x20), shl(248, 1)) // numBlocks = 1
            mstore(add(chunk0, add(0x21, 56)), shl(240, 1)) // numTransactions = 1, block 0
            mstore(add(chunk0, add(0x21, 58)), shl(240, 1)) // numL1Messages = 1, block 0
            mstore(add(chunk0, add(0x21, 60)), shl(192, 1)) // lastAppliedL1Block = 1, block 0
            mstore(add(chunk0, add(0x20, 69)), shl(192, 1)) // lastAppliedL1Block = 1, chunk 0
            mstore(add(chunk0, add(0x20, 77)), 0xb10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf6) // blockRangeHash
        }

        bytes[] memory chunks = new bytes[](1);
        chunks[0] = chunk0;
        bitmap = new bytes(32);

        hevm.startPrank(address(0));
        hevm.expectEmit(true, true, false, true);
        emit CommitBatch(1, bytes32(0xb6448e0bbd8226646f2099cd47160478768e5ccc32b486189073dfcedbad34e3));
        rollup.commitBatch(0, batchHeader0, chunks, bitmap, 0);
        hevm.stopPrank();
        assertBoolEq(rollup.isBatchFinalized(1), false);
        bytes32 batchHash1 = rollup.committedBatches(1);
        assertEq(batchHash1, bytes32(0xb6448e0bbd8226646f2099cd47160478768e5ccc32b486189073dfcedbad34e3));

        // finalize batch1
        hevm.startPrank(address(0));
        hevm.expectEmit(true, true, false, true);
        emit FinalizeBatch(1, batchHash1, bytes32(uint256(2)), bytes32(uint256(3)));
        rollup.finalizeBatchWithProof(
            batchHeader1,
            bytes32(uint256(1)),
            bytes32(uint256(2)),
            bytes32(uint256(3)),
            new bytes(0)
        );
        hevm.stopPrank();
        assertBoolEq(rollup.isBatchFinalized(1), true);
        assertEq(rollup.finalizedStateRoots(1), bytes32(uint256(2)));
        assertEq(rollup.withdrawRoots(1), bytes32(uint256(3)));
        assertEq(rollup.lastFinalizedBatchIndex(), 1);
        assertBoolEq(messageQueue.isMessageSkipped(0), false);
        assertEq(messageQueue.pendingQueueIndex(), 1);
    }

    // commit batch, one chunk with one block, 1 tx, 1 L1 message, no skip, 2 block hash range
    function testCommitBatchTwoBlockHash() public {
        rollup.addSequencer(address(0));
        rollup.addProver(address(0));

        // Roll 256 blocks
        hevm.roll(256);

        // import 300 L1 messages
        for (uint256 i = 0; i < 300; i++) {
            messageQueue.appendCrossDomainMessage(address(this), 1000000, new bytes(0));
        }

        // import genesis batch first
        bytes memory batchHeader0 = new bytes(129);
        assembly {
            mstore(add(batchHeader0, add(0x20, 25)), 1)
        }
        rollup.importGenesisBatch(batchHeader0, bytes32(uint256(1)));
        bytes32 batchHash0 = rollup.committedBatches(0);

        bytes memory bitmap;
        // have only one chunk
        bytes memory chunk0;

        // commit batch1, one chunk with one block, 1 tx, 1 L1 message, no skip
        // => payload for data hash of chunk0
        //   0000000000000000 - blockNumber
        //   0000000000000000 - timestamp
        //   0000000000000000000000000000000000000000000000000000000000000000 - baseFee
        //   0000000000000000 - gasLimit
        //   0001 - numTransactions
        //   0001- numL1Messages
        //   0000000000000002 - lastAppliedL1Block
        //   a2277fd30bbbe74323309023b56035b376d7768ad237ae4fc46ead7dc9591ae1 - L1 Message Tx Hash
        //   0000000000000002 - chunk 0 - lastAppliedL1Block
        //   e90b7bceb6e7df5418fb78d8ee546e97c83a08bbccc01a0644d599ccd2a7c2e0 - chunk 0 - l1BlockRangeHash
        // => data hash for all chunks
        //   7b57de313b5f6add99c3c80246deb99fbdda3735a95e4fb2dded72c874d0c116
        // => payload for batch header
        //   00
        //   0000000000000001
        //   0000000000000001
        //   0000000000000001
        //   7b57de313b5f6add99c3c80246deb99fbdda3735a95e4fb2dded72c874d0c116
        //   743dab51a4c73747185caad9effa81411a067f3d7aa69d69d4b7f3e9802a71c4
        //   0000000000000000000000000000000000000000000000000000000000000000
        //   0000000000000002
        //   7fef4bf8f63cf9dd467136c679c02b5c17fcf6322d9562512bf5eb952cf7cc53
        // => hash for batch header
        //   17a2afe6fe48a603684b7bd5d049de9b8d2093d8c8d927d778cf87a5a553d92c
        bytes memory batchHeader1 = new bytes(129 + 32);
        assembly {
            mstore(add(batchHeader1, 0x20), 0) // version
            mstore(add(batchHeader1, add(0x20, 1)), shl(192, 1)) // batchIndex = 1
            mstore(add(batchHeader1, add(0x20, 9)), shl(192, 1)) // l1MessagePopped = 1
            mstore(add(batchHeader1, add(0x20, 17)), shl(192, 1)) // totalL1MessagePopped = 1
            mstore(add(batchHeader1, add(0x20, 25)), 0x7b57de313b5f6add99c3c80246deb99fbdda3735a95e4fb2dded72c874d0c116) // dataHash
            mstore(add(batchHeader1, add(0x20, 57)), batchHash0) // parentBatchHash
            mstore(add(batchHeader1, add(0x20, 89)), 0) // bitmap0
            mstore(add(batchHeader1, add(0x20, 121)), shl(192, 2)) // lastAppliedL1Block
            mstore(
                add(batchHeader1, add(0x20, 129)),
                0x7fef4bf8f63cf9dd467136c679c02b5c17fcf6322d9562512bf5eb952cf7cc53
            ) // blockRangeHash
        }

        // set chunk data
        chunk0 = new bytes(1 + 108);
        assembly {
            mstore(add(chunk0, 0x20), shl(248, 1)) // numBlocks = 1
            mstore(add(chunk0, add(0x21, 56)), shl(240, 1)) // numTransactions = 1, block 0
            mstore(add(chunk0, add(0x21, 58)), shl(240, 1)) // numL1Messages = 1, block 0
            mstore(add(chunk0, add(0x21, 60)), shl(192, 2)) // lastAppliedL1Block = 1, block 0
            mstore(add(chunk0, add(0x20, 69)), shl(192, 2)) // lastAppliedL1Block = 1, chunk 0
            mstore(add(chunk0, add(0x20, 77)), 0xe90b7bceb6e7df5418fb78d8ee546e97c83a08bbccc01a0644d599ccd2a7c2e0) // blockRangeHash (1-2)
        }

        bytes[] memory chunks = new bytes[](1);
        chunks[0] = chunk0;
        bitmap = new bytes(32);

        hevm.startPrank(address(0));
        hevm.expectEmit(true, true, false, true);
        emit CommitBatch(1, bytes32(0x17a2afe6fe48a603684b7bd5d049de9b8d2093d8c8d927d778cf87a5a553d92c));
        rollup.commitBatch(0, batchHeader0, chunks, bitmap, 0);
        hevm.stopPrank();
        assertBoolEq(rollup.isBatchFinalized(1), false);
        bytes32 batchHash1 = rollup.committedBatches(1);
        assertEq(batchHash1, bytes32(0x17a2afe6fe48a603684b7bd5d049de9b8d2093d8c8d927d778cf87a5a553d92c));

        // finalize batch1
        hevm.startPrank(address(0));
        hevm.expectEmit(true, true, false, true);
        emit FinalizeBatch(1, batchHash1, bytes32(uint256(2)), bytes32(uint256(3)));
        rollup.finalizeBatchWithProof(
            batchHeader1,
            bytes32(uint256(1)),
            bytes32(uint256(2)),
            bytes32(uint256(3)),
            new bytes(0)
        );
        hevm.stopPrank();
        assertBoolEq(rollup.isBatchFinalized(1), true);
        assertEq(rollup.finalizedStateRoots(1), bytes32(uint256(2)));
        assertEq(rollup.withdrawRoots(1), bytes32(uint256(3)));
        assertEq(rollup.lastFinalizedBatchIndex(), 1);
        assertBoolEq(messageQueue.isMessageSkipped(0), false);
        assertEq(messageQueue.pendingQueueIndex(), 1);
    }

    // commit batch, one chunk with one block, 1 tx, 1 L1 message, no skip, 256 block hashes range
    function testCommitBatchMaxBlockHashes() public {
        rollup.addSequencer(address(0));
        rollup.addProver(address(0));

        // Roll 257 blocks
        hevm.roll(257);

        // import 300 L1 messages
        for (uint256 i = 0; i < 300; i++) {
            messageQueue.appendCrossDomainMessage(address(this), 1000000, new bytes(0));
        }

        // import genesis batch first
        bytes memory batchHeader0 = new bytes(129);
        assembly {
            mstore(add(batchHeader0, add(0x20, 25)), 1)
        }
        rollup.importGenesisBatch(batchHeader0, bytes32(uint256(1)));
        bytes32 batchHash0 = rollup.committedBatches(0);

        bytes memory bitmap;
        // have only one chunk
        bytes memory chunk0;

        // commit batch1, one chunk with one block, 1 tx, 1 L1 message, no skip
        // => payload for data hash of chunk0
        //   0000000000000000 - blockNumber
        //   0000000000000000 - timestamp
        //   0000000000000000000000000000000000000000000000000000000000000000 - baseFee
        //   0000000000000000 - gasLimit
        //   0001 - numTransactions
        //   0001- numL1Messages
        //   00000000000000ff - lastAppliedL1Block
        //   a2277fd30bbbe74323309023b56035b376d7768ad237ae4fc46ead7dc9591ae1 - L1 Message Tx Hash
        //   00000000000000ff - chunk 0 - lastAppliedL1Block
        //   31ec624678c8b0057c3c01bc034b716fe904a41b47d3cd08ff0a525dd8041949 - chunk 0 - l1BlockRangeHash
        // => data hash for all chunks
        //   2572331854a9b44d1d0cd8fa8455d80ce80fc515057705c471287f0147d2b023
        // => payload for batch header
        //   00
        //   0000000000000001
        //   0000000000000001
        //   0000000000000001
        //   2572331854a9b44d1d0cd8fa8455d80ce80fc515057705c471287f0147d2b023
        //   743dab51a4c73747185caad9effa81411a067f3d7aa69d69d4b7f3e9802a71c4
        //   0000000000000000000000000000000000000000000000000000000000000000
        //   00000000000000ff
        //   4eeccac9884cddf06b0dd1469927028d64f9a184f3525376d0a9dbce70e9b762
        // => hash for batch header
        //   f1c476cd8725b8c5e5d66a60522a12144ec3acbb2b6f213cca3650df8b1e297f
        bytes memory batchHeader1 = new bytes(129 + 32);
        assembly {
            mstore(add(batchHeader1, 0x20), 0) // version
            mstore(add(batchHeader1, add(0x20, 1)), shl(192, 1)) // batchIndex = 1
            mstore(add(batchHeader1, add(0x20, 9)), shl(192, 1)) // l1MessagePopped = 1
            mstore(add(batchHeader1, add(0x20, 17)), shl(192, 1)) // totalL1MessagePopped = 1
            mstore(add(batchHeader1, add(0x20, 25)), 0x2572331854a9b44d1d0cd8fa8455d80ce80fc515057705c471287f0147d2b023) // dataHash
            mstore(add(batchHeader1, add(0x20, 57)), batchHash0) // parentBatchHash
            mstore(add(batchHeader1, add(0x20, 89)), 0) // bitmap0
            mstore(add(batchHeader1, add(0x20, 121)), shl(192, 256)) // lastAppliedL1Block
            mstore(
                add(batchHeader1, add(0x20, 129)),
                0x4eeccac9884cddf06b0dd1469927028d64f9a184f3525376d0a9dbce70e9b762
            ) // blockRangeHash
        }

        // set chunk data
        chunk0 = new bytes(1 + 108);
        assembly {
            mstore(add(chunk0, 0x20), shl(248, 1)) // numBlocks = 1
            mstore(add(chunk0, add(0x21, 56)), shl(240, 1)) // numTransactions = 1, block 0
            mstore(add(chunk0, add(0x21, 58)), shl(240, 1)) // numL1Messages = 1, block 0
            mstore(add(chunk0, add(0x21, 60)), shl(192, 256)) // lastAppliedL1Block = 256, block 0
            mstore(add(chunk0, add(0x20, 69)), shl(192, 256)) // lastAppliedL1Block = 256, chunk 0
            mstore(add(chunk0, add(0x20, 77)), 0x31ec624678c8b0057c3c01bc034b716fe904a41b47d3cd08ff0a525dd8041949) // blockRangeHash (1-256)
        }

        bytes[] memory chunks = new bytes[](1);
        chunks[0] = chunk0;
        bitmap = new bytes(32);

        hevm.startPrank(address(0));
        hevm.expectEmit(true, true, false, true);
        emit CommitBatch(1, bytes32(0xf1c476cd8725b8c5e5d66a60522a12144ec3acbb2b6f213cca3650df8b1e297f));
        rollup.commitBatch(0, batchHeader0, chunks, bitmap, 0);
        hevm.stopPrank();
        assertBoolEq(rollup.isBatchFinalized(1), false);
        bytes32 batchHash1 = rollup.committedBatches(1);
        assertEq(batchHash1, bytes32(0xf1c476cd8725b8c5e5d66a60522a12144ec3acbb2b6f213cca3650df8b1e297f));

        // finalize batch1
        hevm.startPrank(address(0));
        hevm.expectEmit(true, true, false, true);
        emit FinalizeBatch(1, batchHash1, bytes32(uint256(2)), bytes32(uint256(3)));
        rollup.finalizeBatchWithProof(
            batchHeader1,
            bytes32(uint256(1)),
            bytes32(uint256(2)),
            bytes32(uint256(3)),
            new bytes(0)
        );
        hevm.stopPrank();
        assertBoolEq(rollup.isBatchFinalized(1), true);
        assertEq(rollup.finalizedStateRoots(1), bytes32(uint256(2)));
        assertEq(rollup.withdrawRoots(1), bytes32(uint256(3)));
        assertEq(rollup.lastFinalizedBatchIndex(), 1);
        assertBoolEq(messageQueue.isMessageSkipped(0), false);
        assertEq(messageQueue.pendingQueueIndex(), 1);
    }

    function testAddAndRemoveProver(address _prover) public {
        // set by non-owner, should revert
        hevm.startPrank(address(1));
        hevm.expectRevert("Ownable: caller is not the owner");
        rollup.addProver(_prover);
        hevm.expectRevert("Ownable: caller is not the owner");
        rollup.removeProver(_prover);
        hevm.stopPrank();

        hevm.expectRevert("not EOA");
        rollup.addProver(address(this));
        hevm.assume(_prover.code.length == 0);

        // change to random EOA operator
        hevm.expectEmit(true, false, false, true);
        emit UpdateProver(_prover, true);

        assertBoolEq(rollup.isProver(_prover), false);
        rollup.addProver(_prover);
        assertBoolEq(rollup.isProver(_prover), true);

        hevm.expectEmit(true, false, false, true);
        emit UpdateProver(_prover, false);
        rollup.removeProver(_prover);
        assertBoolEq(rollup.isProver(_prover), false);
    }

    function testSetPause() external {
        rollup.addSequencer(address(0));
        rollup.addProver(address(0));

        // not owner, revert
        hevm.startPrank(address(1));
        hevm.expectRevert("Ownable: caller is not the owner");
        rollup.setPause(false);
        hevm.stopPrank();

        // pause
        rollup.setPause(true);
        assertBoolEq(true, rollup.paused());

        hevm.startPrank(address(0));
        hevm.expectRevert("Pausable: paused");
        rollup.commitBatch(0, new bytes(0), new bytes[](0), new bytes(0), 0);
        hevm.expectRevert("Pausable: paused");
        rollup.finalizeBatchWithProof(new bytes(0), bytes32(0), bytes32(0), bytes32(0), new bytes(0));
        hevm.stopPrank();

        // unpause
        rollup.setPause(false);
        assertBoolEq(false, rollup.paused());
    }

    function testUpdateVerifier(address _newVerifier) public {
        // set by non-owner, should revert
        hevm.startPrank(address(1));
        hevm.expectRevert("Ownable: caller is not the owner");
        rollup.updateVerifier(_newVerifier);
        hevm.stopPrank();

        // change to random operator
        hevm.expectEmit(true, true, false, true);
        emit UpdateVerifier(address(verifier), _newVerifier);

        assertEq(rollup.verifier(), address(verifier));
        rollup.updateVerifier(_newVerifier);
        assertEq(rollup.verifier(), _newVerifier);
    }

    function testUpdateMaxNumTxInChunk(uint256 _maxNumTxInChunk) public {
        // set by non-owner, should revert
        hevm.startPrank(address(1));
        hevm.expectRevert("Ownable: caller is not the owner");
        rollup.updateMaxNumTxInChunk(_maxNumTxInChunk);
        hevm.stopPrank();

        // change to random operator
        hevm.expectEmit(false, false, false, true);
        emit UpdateMaxNumTxInChunk(100, _maxNumTxInChunk);

        assertEq(rollup.maxNumTxInChunk(), 100);
        rollup.updateMaxNumTxInChunk(_maxNumTxInChunk);
        assertEq(rollup.maxNumTxInChunk(), _maxNumTxInChunk);
    }

    function testImportGenesisBlock() public {
        bytes memory batchHeader;

        // zero state root, revert
        batchHeader = new bytes(129);
        hevm.expectRevert("zero state root");
        rollup.importGenesisBatch(batchHeader, bytes32(0));

        // batch header length too small, revert
        batchHeader = new bytes(128);
        hevm.expectRevert("batch header length too small");
        rollup.importGenesisBatch(batchHeader, bytes32(uint256(1)));

        // wrong bitmap length, revert
        batchHeader = new bytes(130);
        hevm.expectRevert("wrong bitmap length");
        rollup.importGenesisBatch(batchHeader, bytes32(uint256(1)));

        // not all fields are zero, revert
        batchHeader = new bytes(129);
        batchHeader[0] = bytes1(uint8(1)); // version not zero
        hevm.expectRevert("not all fields are zero");
        rollup.importGenesisBatch(batchHeader, bytes32(uint256(1)));

        batchHeader = new bytes(129);
        batchHeader[1] = bytes1(uint8(1)); // batchIndex not zero
        hevm.expectRevert("not all fields are zero");
        rollup.importGenesisBatch(batchHeader, bytes32(uint256(1)));

        batchHeader = new bytes(129 + 32);
        assembly {
            mstore(add(batchHeader, add(0x20, 9)), shl(192, 1)) // l1MessagePopped not zero
        }
        hevm.expectRevert("not all fields are zero");
        rollup.importGenesisBatch(batchHeader, bytes32(uint256(1)));

        batchHeader = new bytes(129);
        batchHeader[17] = bytes1(uint8(1)); // totalL1MessagePopped not zero
        hevm.expectRevert("not all fields are zero");
        rollup.importGenesisBatch(batchHeader, bytes32(uint256(1)));

        // zero data hash, revert
        batchHeader = new bytes(129);
        hevm.expectRevert("zero data hash");
        rollup.importGenesisBatch(batchHeader, bytes32(uint256(1)));

        // nonzero parent batch hash, revert
        batchHeader = new bytes(129);
        batchHeader[25] = bytes1(uint8(1)); // dataHash not zero
        batchHeader[57] = bytes1(uint8(1)); // parentBatchHash not zero
        hevm.expectRevert("nonzero parent batch hash");
        rollup.importGenesisBatch(batchHeader, bytes32(uint256(1)));

        // import correctly
        batchHeader = new bytes(129);
        batchHeader[25] = bytes1(uint8(1)); // dataHash not zero
        assertEq(rollup.finalizedStateRoots(0), bytes32(0));
        assertEq(rollup.withdrawRoots(0), bytes32(0));
        assertEq(rollup.committedBatches(0), bytes32(0));
        rollup.importGenesisBatch(batchHeader, bytes32(uint256(1)));
        assertEq(rollup.finalizedStateRoots(0), bytes32(uint256(1)));
        assertEq(rollup.withdrawRoots(0), bytes32(0));
        assertGt(uint256(rollup.committedBatches(0)), 0);

        // Genesis batch imported, revert
        hevm.expectRevert("Genesis batch imported");
        rollup.importGenesisBatch(batchHeader, bytes32(uint256(1)));
    }
}
