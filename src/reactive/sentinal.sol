// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "lib/reactive-lib/src/abstract-base/AbstractReactive.sol";
import {IReactive} from "lib/reactive-lib/src/interfaces/IReactive.sol";

contract Sentinal is AbstractReactive {
    uint256 public originChainId;
    uint256 public destinationChainId;
    address public market;
    address public oracle;
    address public executor;
    address public callback;
    uint64 public callbackGasLimit;
    uint256 public cronTopic;
    uint256 public batchSize;
    uint256 public batchesPerTrigger;

    error InvalidAddress();

    constructor(
        uint256 originChainId_,
        uint256 destinationChainId_,
        address market_,
        address oracle_,
        address executor_,
        address callback_,
        uint64 callbackGasLimit_,
        uint256 cronTopic_,
        uint256 batchSize_,
        uint256 batchesPerTrigger_
    ) payable {
        if (market_ == address(0) || callback_ == address(0)) revert InvalidAddress();

        originChainId = originChainId_;
        destinationChainId = destinationChainId_;
        market = market_;
        oracle = oracle_;
        executor = executor_;
        callback = callback_;
        callbackGasLimit = callbackGasLimit_;
        cronTopic = cronTopic_;
        batchSize = batchSize_;
        batchesPerTrigger = batchesPerTrigger_ == 0 ? 1 : batchesPerTrigger_;

        if (!vm) {
            service.subscribe(
                originChainId_, market_, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            );
            if (oracle_ != address(0)) {
                service.subscribe(
                    originChainId_, oracle_, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
                );
            }
            if (executor_ != address(0)) {
                service.subscribe(
                    destinationChainId_, executor_, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
                );
            }
            if (cronTopic_ != 0) {
                service.subscribe(0, address(0), cronTopic_, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
            }
        }
    }

    function react(IReactive.LogRecord calldata log) external vmOnly {
        if (log.topic_0 == REACTIVE_IGNORE) return;

        if (cronTopic != 0 && log.topic_0 == cronTopic) {
            bytes memory cronPayload = abi.encodeWithSignature(
                "processNextBatchEvent(address,address,uint256,uint256,uint256,uint256,uint256,uint256)",
                address(0),
                market,
                batchSize,
                log.chain_id,
                log.block_number,
                log.tx_hash,
                log.log_index,
                log.topic_0
            );
            for (uint256 i = 0; i < batchesPerTrigger; i++) {
                emit Callback(destinationChainId, callback, callbackGasLimit, cronPayload);
            }
            return;
        }

        if (executor != address(0) && log.chain_id == destinationChainId && log._contract == executor) {
            if (log.topic_0 == uint256(keccak256("LiquidationExecuted(address,address,bool,uint256)"))) {
                address eventMarket = _extractAddress(log.topic_1);
                bytes memory execPayload = abi.encodeWithSignature(
                    "processNextBatchEvent(address,address,uint256,uint256,uint256,uint256,uint256,uint256)",
                    address(0),
                    eventMarket == address(0) ? market : eventMarket,
                    batchSize,
                    log.chain_id,
                    log.block_number,
                    log.tx_hash,
                    log.log_index,
                    log.topic_0
                );
                for (uint256 i = 0; i < batchesPerTrigger; i++) {
                    emit Callback(destinationChainId, callback, callbackGasLimit, execPayload);
                }
            }
            return;
        }

        if (log.chain_id != originChainId) return;
        if (oracle != address(0) && log._contract == oracle) {
            bytes memory oraclePayload = abi.encodeWithSignature(
                "processNextBatchEvent(address,address,uint256,uint256,uint256,uint256,uint256,uint256)",
                address(0),
                market,
                batchSize,
                log.chain_id,
                log.block_number,
                log.tx_hash,
                log.log_index,
                log.topic_0
            );
            for (uint256 i = 0; i < batchesPerTrigger; i++) {
                emit Callback(destinationChainId, callback, callbackGasLimit, oraclePayload);
            }
            return;
        }
        if (log._contract != market) return;

        address account = _extractAddress(log.topic_1);
        if (account == address(0)) account = _extractAddress(log.topic_2);
        if (account == address(0)) account = _extractAddress(log.topic_3);
        if (account == address(0)) {
            bytes memory batchPayload = abi.encodeWithSignature(
                "processNextBatchEvent(address,address,uint256,uint256,uint256,uint256,uint256,uint256)",
                address(0),
                market,
                batchSize,
                log.chain_id,
                log.block_number,
                log.tx_hash,
                log.log_index,
                log.topic_0
            );
            for (uint256 i = 0; i < batchesPerTrigger; i++) {
                emit Callback(destinationChainId, callback, callbackGasLimit, batchPayload);
            }
        } else {
            bytes memory eventPayload = abi.encodeWithSignature(
                "trackAndCheckEvent(address,address,address,uint256,uint256,uint256,uint256,uint256)",
                address(0),
                market,
                account,
                log.chain_id,
                log.block_number,
                log.tx_hash,
                log.log_index,
                log.topic_0
            );
            emit Callback(destinationChainId, callback, callbackGasLimit, eventPayload);
        }
    }

    function _extractAddress(uint256 topic) internal pure returns (address) {
        if (topic == 0) return address(0);
        if (topic >> 160 != 0) return address(0);
        address a;
        assembly {
            a := and(topic, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
        }
        return a;
    }
}
