package watcher

import (
	"context"
	"errors"
	"fmt"
	"math/big"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/scroll-tech/go-ethereum"
	"github.com/scroll-tech/go-ethereum/accounts/abi"
	"github.com/scroll-tech/go-ethereum/common"
	gethTypes "github.com/scroll-tech/go-ethereum/core/types"
	"github.com/scroll-tech/go-ethereum/ethclient"
	"github.com/scroll-tech/go-ethereum/log"
	"gorm.io/gorm"

	"scroll-tech/common/types"
	bridgeAbi "scroll-tech/rollup/abi"

	"scroll-tech/rollup/internal/config"
	"scroll-tech/rollup/internal/orm"
)

// chunkRowConsumption is map(sub-circuit name => sub-circuit row count)
type chunkRowConsumption map[string]uint64

// add accumulates row consumption per sub-circuit
func (crc *chunkRowConsumption) add(rowConsumption *gethTypes.RowConsumption) error {
	if rowConsumption == nil {
		return errors.New("rowConsumption is <nil>")
	}
	for _, subCircuit := range *rowConsumption {
		(*crc)[subCircuit.Name] += subCircuit.RowNumber
	}
	return nil
}

// max finds the maximum row consumption among all sub-circuits
func (crc *chunkRowConsumption) max() uint64 {
	var max uint64
	for _, value := range *crc {
		if value > max {
			max = value
		}
	}
	return max
}

// ChunkProposer proposes chunks based on available unchunked blocks.
type ChunkProposer struct {
	ctx context.Context
	db  *gorm.DB

	*ethclient.Client
	l1ViewOracleAddress common.Address

	chunkOrm        *orm.Chunk
	l2BlockOrm      *orm.L2Block
	l1ViewOracleABI *abi.ABI

	maxBlockNumPerChunk             uint64
	maxTxNumPerChunk                uint64
	maxL1CommitGasPerChunk          uint64
	maxL1CommitCalldataSizePerChunk uint64
	maxRowConsumptionPerChunk       uint64
	chunkTimeoutSec                 uint64
	gasCostIncreaseMultiplier       float64

	chunkProposerCircleTotal           prometheus.Counter
	proposeChunkFailureTotal           prometheus.Counter
	proposeChunkUpdateInfoTotal        prometheus.Counter
	proposeChunkUpdateInfoFailureTotal prometheus.Counter
	chunkTxNum                         prometheus.Gauge
	chunkEstimateL1CommitGas           prometheus.Gauge
	totalL1CommitCalldataSize          prometheus.Gauge
	totalTxGasUsed                     prometheus.Gauge
	maxTxConsumption                   prometheus.Gauge
	chunkBlocksNum                     prometheus.Gauge
	chunkFirstBlockTimeoutReached      prometheus.Counter
	chunkBlocksProposeNotEnoughTotal   prometheus.Counter
}

// NewChunkProposer creates a new ChunkProposer instance.
func NewChunkProposer(ctx context.Context, client *ethclient.Client, cfg *config.ChunkProposerConfig, l1ViewOracleAddress common.Address, db *gorm.DB, reg prometheus.Registerer) (*ChunkProposer, error) {
	if l1ViewOracleAddress == (common.Address{}) {
		return nil, errors.New("must pass non-zero l1ViewOracleAddress to BridgeClient")
	}

	log.Debug("new chunk proposer",
		"maxTxNumPerChunk", cfg.MaxTxNumPerChunk,
		"maxL1CommitGasPerChunk", cfg.MaxL1CommitGasPerChunk,
		"maxL1CommitCalldataSizePerChunk", cfg.MaxL1CommitCalldataSizePerChunk,
		"maxRowConsumptionPerChunk", cfg.MaxRowConsumptionPerChunk,
		"chunkTimeoutSec", cfg.ChunkTimeoutSec,
		"gasCostIncreaseMultiplier", cfg.GasCostIncreaseMultiplier,
	)

	return &ChunkProposer{
		ctx:                             ctx,
		Client:                          client,
		l1ViewOracleAddress:             l1ViewOracleAddress,
		l1ViewOracleABI:                 bridgeAbi.L1ViewOracleABI,
		db:                              db,
		chunkOrm:                        orm.NewChunk(db),
		l2BlockOrm:                      orm.NewL2Block(db),
		maxBlockNumPerChunk:             cfg.MaxBlockNumPerChunk,
		maxTxNumPerChunk:                cfg.MaxTxNumPerChunk,
		maxL1CommitGasPerChunk:          cfg.MaxL1CommitGasPerChunk,
		maxL1CommitCalldataSizePerChunk: cfg.MaxL1CommitCalldataSizePerChunk,
		maxRowConsumptionPerChunk:       cfg.MaxRowConsumptionPerChunk,
		chunkTimeoutSec:                 cfg.ChunkTimeoutSec,
		gasCostIncreaseMultiplier:       cfg.GasCostIncreaseMultiplier,

		chunkProposerCircleTotal: promauto.With(reg).NewCounter(prometheus.CounterOpts{
			Name: "rollup_propose_chunk_circle_total",
			Help: "Total number of propose chunk total.",
		}),
		proposeChunkFailureTotal: promauto.With(reg).NewCounter(prometheus.CounterOpts{
			Name: "rollup_propose_chunk_failure_circle_total",
			Help: "Total number of propose chunk failure total.",
		}),
		proposeChunkUpdateInfoTotal: promauto.With(reg).NewCounter(prometheus.CounterOpts{
			Name: "rollup_propose_chunk_update_info_total",
			Help: "Total number of propose chunk update info total.",
		}),
		proposeChunkUpdateInfoFailureTotal: promauto.With(reg).NewCounter(prometheus.CounterOpts{
			Name: "rollup_propose_chunk_update_info_failure_total",
			Help: "Total number of propose chunk update info failure total.",
		}),
		chunkTxNum: promauto.With(reg).NewGauge(prometheus.GaugeOpts{
			Name: "rollup_propose_chunk_tx_num",
			Help: "The chunk tx num",
		}),
		chunkEstimateL1CommitGas: promauto.With(reg).NewGauge(prometheus.GaugeOpts{
			Name: "rollup_propose_chunk_estimate_l1_commit_gas",
			Help: "The chunk estimate l1 commit gas",
		}),
		totalL1CommitCalldataSize: promauto.With(reg).NewGauge(prometheus.GaugeOpts{
			Name: "rollup_propose_chunk_total_l1_commit_call_data_size",
			Help: "The total l1 commit call data size",
		}),
		totalTxGasUsed: promauto.With(reg).NewGauge(prometheus.GaugeOpts{
			Name: "rollup_propose_chunk_total_tx_gas_used",
			Help: "The total tx gas used",
		}),
		maxTxConsumption: promauto.With(reg).NewGauge(prometheus.GaugeOpts{
			Name: "rollup_propose_chunk_max_tx_consumption",
			Help: "The max tx consumption",
		}),
		chunkBlocksNum: promauto.With(reg).NewGauge(prometheus.GaugeOpts{
			Name: "rollup_propose_chunk_chunk_block_number",
			Help: "The number of blocks in the chunk",
		}),
		chunkFirstBlockTimeoutReached: promauto.With(reg).NewCounter(prometheus.CounterOpts{
			Name: "rollup_propose_chunk_first_block_timeout_reached_total",
			Help: "Total times of chunk's first block timeout reached",
		}),
		chunkBlocksProposeNotEnoughTotal: promauto.With(reg).NewCounter(prometheus.CounterOpts{
			Name: "rollup_propose_chunk_blocks_propose_not_enough_total",
			Help: "Total number of chunk block propose not enough",
		}),
	}, nil
}

// TryProposeChunk tries to propose a new chunk.
func (p *ChunkProposer) TryProposeChunk() {
	parentChunk, err := p.chunkOrm.GetLatestChunk(p.ctx)
	if err != nil && !errors.Is(errors.Unwrap(err), gorm.ErrRecordNotFound) {
		log.Error("failed to get latest chunk", "err", err)
		return
	}

	p.chunkProposerCircleTotal.Inc()
	proposedChunk, err := p.proposeChunk(parentChunk)
	if err != nil {
		p.proposeChunkFailureTotal.Inc()
		log.Error("propose new chunk failed", "err", err)
		return
	}

	if err := p.updateChunkInfoInDB(parentChunk, proposedChunk); err != nil {
		p.proposeChunkUpdateInfoFailureTotal.Inc()
		log.Error("update chunk info in orm failed", "err", err)
	}
}

func (p *ChunkProposer) updateChunkInfoInDB(parentChunk *orm.Chunk, chunk *types.Chunk) error {
	if chunk == nil {
		return nil
	}

	p.proposeChunkUpdateInfoTotal.Inc()
	err := p.db.Transaction(func(dbTX *gorm.DB) error {
		dbChunk, err := p.chunkOrm.InsertChunk(p.ctx, parentChunk, chunk, dbTX)
		if err != nil {
			log.Warn("ChunkProposer.InsertChunk failed", "chunk hash", chunk.Hash)
			return err
		}
		if err := p.l2BlockOrm.UpdateChunkHashInRange(p.ctx, dbChunk.StartBlockNumber, dbChunk.EndBlockNumber, dbChunk.Hash, dbTX); err != nil {
			log.Error("failed to update chunk_hash for l2_blocks", "chunk hash", chunk.Hash, "start block", 0, "end block", 0, "err", err)
			return err
		}
		return nil
	})
	return err
}

func (p *ChunkProposer) proposeChunk(parentChunk *orm.Chunk) (*types.Chunk, error) {
	unchunkedBlockHeight, err := p.chunkOrm.GetUnchunkedBlockHeight(p.ctx)
	if err != nil {
		return nil, err
	}

	// select at most p.maxBlockNumPerChunk blocks
	blocks, err := p.l2BlockOrm.GetL2WrappedBlocksGEHeight(p.ctx, unchunkedBlockHeight, int(p.maxBlockNumPerChunk))
	if err != nil {
		return nil, err
	}

	if len(blocks) == 0 {
		return nil, nil
	}

	var chunk types.Chunk
	var totalTxGasUsed uint64
	var totalTxNum uint64
	var totalL1CommitCalldataSize uint64
	var totalL1CommitGas uint64
	crc := chunkRowConsumption{}
	lastAppliedL1Block := blocks[len(blocks)-1].LastAppliedL1Block
	var l1BlockRangeHashFrom uint64

	if parentChunk != nil {
		l1BlockRangeHashFrom = parentChunk.LastAppliedL1Block
		if l1BlockRangeHashFrom != 0 {
			l1BlockRangeHashFrom++
		}
	}

	l1BlockRangeHash, err := p.GetL1BlockRangeHash(p.ctx, l1BlockRangeHashFrom, lastAppliedL1Block)
	if err != nil {
		log.Error("failed to get l1 block range hash", "from", l1BlockRangeHashFrom, "to", lastAppliedL1Block, "err", err)
		return nil, fmt.Errorf("chunk-proposer failed to get l1 block range hash error: %w", err)
	}

	chunk.LastAppliedL1Block = lastAppliedL1Block
	chunk.L1BlockRangeHash = *l1BlockRangeHash

	for i, block := range blocks {
		// metric values
		lastTotalTxNum := totalTxNum
		lastTotalL1CommitGas := totalL1CommitGas
		lastCrcMax := crc.max()
		lastTotalL1CommitCalldataSize := totalL1CommitCalldataSize
		lastTotalTxGasUsed := totalTxGasUsed

		totalTxGasUsed += block.Header.GasUsed
		totalTxNum += uint64(len(block.Transactions))
		totalL1CommitCalldataSize += block.EstimateL1CommitCalldataSize()
		totalL1CommitGas = chunk.EstimateL1CommitGas()
		totalOverEstimateL1CommitGas := uint64(p.gasCostIncreaseMultiplier * float64(totalL1CommitGas))
		if err := crc.add(block.RowConsumption); err != nil {
			return nil, fmt.Errorf("chunk-proposer failed to update chunk row consumption: %v", err)
		}
		crcMax := crc.max()

		if totalTxNum > p.maxTxNumPerChunk ||
			totalL1CommitCalldataSize > p.maxL1CommitCalldataSizePerChunk ||
			totalOverEstimateL1CommitGas > p.maxL1CommitGasPerChunk ||
			crcMax > p.maxRowConsumptionPerChunk {
			// Check if the first block breaks hard limits.
			// If so, it indicates there are bugs in sequencer, manual fix is needed.
			if i == 0 {
				if totalTxNum > p.maxTxNumPerChunk {
					return nil, fmt.Errorf(
						"the first block exceeds l2 tx number limit; block number: %v, number of transactions: %v, max transaction number limit: %v",
						block.Header.Number,
						totalTxNum,
						p.maxTxNumPerChunk,
					)
				}

				if totalOverEstimateL1CommitGas > p.maxL1CommitGasPerChunk {
					return nil, fmt.Errorf(
						"the first block exceeds l1 commit gas limit; block number: %v, commit gas: %v, max commit gas limit: %v",
						block.Header.Number,
						totalL1CommitGas,
						p.maxL1CommitGasPerChunk,
					)
				}

				if totalL1CommitCalldataSize > p.maxL1CommitCalldataSizePerChunk {
					return nil, fmt.Errorf(
						"the first block exceeds l1 commit calldata size limit; block number: %v, calldata size: %v, max calldata size limit: %v",
						block.Header.Number,
						totalL1CommitCalldataSize,
						p.maxL1CommitCalldataSizePerChunk,
					)
				}

				if crcMax > p.maxRowConsumptionPerChunk {
					return nil, fmt.Errorf(
						"the first block exceeds row consumption limit; block number: %v, row consumption: %v, max: %v, limit: %v",
						block.Header.Number,
						crc,
						crcMax,
						p.maxRowConsumptionPerChunk,
					)
				}
			}

			log.Debug("breaking limit condition in chunking",
				"totalTxNum", totalTxNum,
				"maxTxNumPerChunk", p.maxTxNumPerChunk,
				"currentL1CommitCalldataSize", totalL1CommitCalldataSize,
				"maxL1CommitCalldataSizePerChunk", p.maxL1CommitCalldataSizePerChunk,
				"currentOverEstimateL1CommitGas", totalOverEstimateL1CommitGas,
				"maxL1CommitGasPerChunk", p.maxL1CommitGasPerChunk,
				"chunkRowConsumptionMax", crcMax,
				"chunkRowConsumption", crc,
				"p.maxRowConsumptionPerChunk", p.maxRowConsumptionPerChunk)

			p.chunkTxNum.Set(float64(lastTotalTxNum))
			p.chunkEstimateL1CommitGas.Set(float64(lastTotalL1CommitGas))
			p.totalL1CommitCalldataSize.Set(float64(lastTotalL1CommitCalldataSize))
			p.maxTxConsumption.Set(float64(lastCrcMax))
			p.totalTxGasUsed.Set(float64(lastTotalTxGasUsed))
			p.chunkBlocksNum.Set(float64(len(chunk.Blocks)))
			return &chunk, nil
		}
		chunk.Blocks = append(chunk.Blocks, block)
	}

	currentTimeSec := uint64(time.Now().Unix())
	if chunk.Blocks[0].Header.Time+p.chunkTimeoutSec < currentTimeSec ||
		uint64(len(chunk.Blocks)) == p.maxBlockNumPerChunk {
		if chunk.Blocks[0].Header.Time+p.chunkTimeoutSec < currentTimeSec {
			log.Warn("first block timeout",
				"block number", chunk.Blocks[0].Header.Number,
				"block timestamp", chunk.Blocks[0].Header.Time,
				"current time", currentTimeSec,
			)
		} else {
			log.Info("reached maximum number of blocks in chunk",
				"start block number", chunk.Blocks[0].Header.Number,
				"block count", len(chunk.Blocks),
			)
		}

		p.chunkFirstBlockTimeoutReached.Inc()
		p.chunkTxNum.Set(float64(totalTxNum))
		p.chunkEstimateL1CommitGas.Set(float64(totalL1CommitGas))
		p.totalL1CommitCalldataSize.Set(float64(totalL1CommitCalldataSize))
		p.maxTxConsumption.Set(float64(crc.max()))
		p.totalTxGasUsed.Set(float64(totalTxGasUsed))
		p.chunkBlocksNum.Set(float64(len(chunk.Blocks)))
		return &chunk, nil
	}

	log.Debug("pending blocks do not reach one of the constraints or contain a timeout block")
	p.chunkBlocksProposeNotEnoughTotal.Inc()
	return nil, nil
}

// GetL1BlockRangeHash gets l1 block range hash from l1 view oracle smart contract.
func (p *ChunkProposer) GetL1BlockRangeHash(ctx context.Context, from uint64, to uint64) (*common.Hash, error) {
	input, err := p.l1ViewOracleABI.Pack("blockRangeHash", big.NewInt(int64(from)), big.NewInt(int64(to)))
	if err != nil {
		return nil, err
	}

	output, err := p.Client.CallContract(ctx, ethereum.CallMsg{
		To:   &p.l1ViewOracleAddress,
		Data: input,
	}, nil)
	if err != nil {
		return nil, err
	}
	if len(output) == 0 {
		if code, err := p.Client.CodeAt(ctx, p.l1ViewOracleAddress, nil); err != nil {
			return nil, err
		} else if len(code) == 0 {
			return nil, fmt.Errorf(
				"l1 view oracle contract unknown, address: %v",
				p.l1ViewOracleAddress,
			)
		}
	}

	result, err := p.l1ViewOracleABI.Unpack("blockRangeHash", output)
	if err != nil {
		return nil, err
	}

	b, ok := result[0].([32]byte)
	if !ok {
		return nil, fmt.Errorf("could not cast block range hash to [32]byte")
	}

	l1BlockRangeHash := common.Hash(b)

	return &l1BlockRangeHash, nil
}
