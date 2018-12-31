{-# LANGUAGE RecordWildCards #-}
{- |
Description: Contains functions for working with the file Buffer.

As we collect more and more Pieces of the file(s) we want to download
from peers, we need a data structure around which to choose pieces,
and to be able to fill with pieces. The data structure should also
let us save to a file.
-}
module Haze.PieceBuffer
    ()
where

import           Relude

import           Data.Array                     ( Array
                                                , listArray
                                                )

import           Haze.Tracker                   ( SHAPieces(..)
                                                , MetaInfo(..)
                                                , totalFileLength
                                                )


-- | The size of a piece composing the torrent
type PieceSize = Int64

-- | The size of a block composing a piece
type BlockSize = Int64


-- | Represents a buffer of pieces composing the file(s) to download
data PieceBuffer = PieceBuffer !SHAPieces !(Array Int Piece)

-- | Represents one of the pieces composing 
data Piece
    -- | A fully downloaded, and saved piece
    = Saved
    -- | A complete, but not yet saved or checked piece 
    | Complete !ByteString
    -- | An incomplete set of blocks composing a this piece
    | Incomplete !(Array Int Block)


{- | Represents a block of data sub dividing a piece

Blocks are the unit of data actually downloaded from peers,
and thus are the unit of data a peer can stake a claim on.
-}
data Block
    -- | An empty block no one has tagged
    = FreeBlock
    -- | A block that someone is downloading
    | TaggedBlock
    -- | A fully downloaded block
    | FullBlock !ByteString


{- | Construct a piece buffer from total size, piece size, and block size

This exists mainly as a tool for testing the implementation of piece buffers.
usually you want to make a piece buffer corresponding to the configuration
of an actual torrent file, in which case 'makePieceBuffer' should be used
-}
sizedPieceBuffer :: Int64 -> SHAPieces -> BlockSize -> PieceBuffer
sizedPieceBuffer totalSize shaPieces@(SHAPieces pieceSize _) blockSize =
    let pieces        = makePiece blockSize <$> chunkSizes totalSize pieceSize
        maxPieceIndex = fromIntegral $ div totalSize pieceSize
        pieceArr      = listArray (0, maxPieceIndex) pieces
    in  PieceBuffer shaPieces pieceArr
  where
    chunkSizes :: Integral a => a -> a -> [a]
    chunkSizes total size =
        let (d, m) = divMod total size in replicate (fromIntegral d) d ++ [m]

{- | Construct a piece buffer given a block size and a torrent file

The block size controls the size of each downloadable chunk inside
of an individual piece composing the data to download. Usually
the default in this module should use.
-}
makePieceBuffer :: BlockSize -> MetaInfo -> PieceBuffer
makePieceBuffer blockSize MetaInfo {..} =
    let totalLength = totalFileLength metaFile
    in  sizedPieceBuffer totalLength metaPieces blockSize

{- Construct a new piece given the piece size, and the block size

Each piece in a torrent has the same size, except for the last one.
The block size can be set when constructing a piece buffer
-}
makePiece :: BlockSize -> PieceSize -> Piece
makePiece blockSize pieceSize =
    let maxBlockIndex = fromIntegral $ div pieceSize blockSize
    in  Incomplete . listArray (0, maxBlockIndex) $ repeat FreeBlock
