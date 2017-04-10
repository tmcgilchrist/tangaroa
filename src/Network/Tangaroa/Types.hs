{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

module Network.Tangaroa.Types
  ( Raft
  , RaftSpec(..)
  , LiftedRaftSpec(..)
  , readLogEntry, writeLogEntry, readTermNumber, writeTermNumber
  , readVotedFor, writeVotedFor, applyLogEntry, serializeRPC
  , deserializeRPC, sendMessage, getMessage, debugPrint
  , liftRaftSpec
  , Term, startTerm
  , LogIndex, startIndex
  , RequestId, startRequestId
  , Config(..), otherNodes, nodeId, electionTimeoutRange, heartbeatTimeout, enableDebug
  , Role(..)
  , RaftEnv(..), cfg, quorumSize, eventIn, eventOut, rs
  , RaftState(..), role, votedFor, currentLeader, logEntries, commitIndex, lastApplied, timerThread
  , pendingRequests, nextRequestId
  , initialRaftState
  , cYesVotes, cPotentialVotes, lNextIndex, lMatchIndex
  , AppendEntries(..)
  , AppendEntriesResponse(..)
  , RequestVote(..)
  , RequestVoteResponse(..)
  , Command(..)
  , CommandResponse(..)
  , RPC(..)
  , term
  , Event(..)
  ) where

import           Control.Concurrent (ThreadId)
import           Control.Concurrent.Chan.Unagi
import           Control.Lens hiding (Index)
import           Control.Monad.RWS
import           Data.Binary
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import           Data.Set (Set)
import qualified Data.Set as Set

import           GHC.Generics

newtype Term = Term Int
  deriving (Show, Read, Eq, Ord, Generic, Num)

startTerm :: Term
startTerm = Term (-1)

type LogIndex = Int

startIndex :: LogIndex
startIndex = (-1)

newtype RequestId = RequestId Int
  deriving (Show, Read, Eq, Ord, Generic, Num)

startRequestId :: RequestId
startRequestId = RequestId 0

data Config nt = Config
  { _otherNodes           :: Set nt
  , _nodeId               :: nt
  , _electionTimeoutRange :: (Int,Int) -- in microseconds
  , _heartbeatTimeout     :: Int       -- in microseconds
  , _enableDebug          :: Bool
  }
  deriving (Show, Generic)
makeLenses ''Config

data Command nt et = Command
  { _cmdEntry     :: et
  , _cmdClientId  :: nt
  , _cmdRequestId :: RequestId
  }
  deriving (Show, Read, Generic)

data CommandResponse nt rt = CommandResponse
  { _cmdrResult    :: rt
  , _cmdrLeaderId  :: nt
  , _cmdrRequestId :: RequestId
  }
  deriving (Show, Read, Generic)

data AppendEntries nt et = AppendEntries
  { _aeTerm       :: Term
  , _leaderId     :: nt
  , _prevLogIndex :: LogIndex
  , _prevLogTerm  :: Term
  , _aeEntries    :: Seq (Term, Command nt et)
  , _leaderCommit :: LogIndex
  }
  deriving (Show, Read, Generic)

data AppendEntriesResponse nt = AppendEntriesResponse
  { _aerTerm    :: Term
  , _aerNodeId  :: nt
  , _aerSuccess :: Bool
  , _aerIndex   :: LogIndex
  }
  deriving (Show, Read, Generic)

data RequestVote nt = RequestVote
  { _rvTerm       :: Term
  , _candidateId  :: nt
  , _lastLogIndex :: LogIndex
  , _lastLogTerm  :: Term
  }
  deriving (Show, Read, Generic)

data RequestVoteResponse nt = RequestVoteResponse
  { _rvrTerm     :: Term
  , _rvrNodeId   :: nt
  , _voteGranted :: Bool
  }
  deriving (Show, Read, Generic)

data RPC nt et rt = AE (AppendEntries nt et)
                  | AER (AppendEntriesResponse nt)
                  | RV (RequestVote nt)
                  | RVR (RequestVoteResponse nt)
                  | CMD (Command nt et)
                  | CMDR (CommandResponse nt rt)
                  | DBG String
  deriving (Show, Read, Generic)

-- | A structure containing all the implementation details for running
-- the raft protocol.
data RaftSpec nt et rt mt = RaftSpec
  {
    -- ^ Function to get a log entry from persistent storage.
    __readLogEntry     :: LogIndex -> IO (Maybe et)

    -- ^ Function to write a log entry to persistent storage.
  , __writeLogEntry    :: LogIndex -> (Term,et) -> IO ()

    -- ^ Function to get the term number from persistent storage.
  , __readTermNumber   :: IO Term

    -- ^ Function to write the term number to persistent storage.
  , __writeTermNumber  :: Term -> IO ()

    -- ^ Function to read the node voted for from persistent storage.
  , __readVotedFor     :: IO (Maybe nt)

    -- ^ Function to write the node voted for to persistent storage.
  , __writeVotedFor    :: Maybe nt -> IO ()

    -- ^ Function to apply a log entry to the state machine.
  , __applyLogEntry    :: et -> IO rt

    -- ^ Function to serialize an RPC.
  , __serializeRPC     :: RPC nt et rt -> mt

    -- ^ Function to deserialize an RPC.
  , __deserializeRPC   :: mt -> Maybe (RPC nt et rt)

    -- ^ Function to send a message to a node.
  , __sendMessage      :: nt -> mt -> IO ()

    -- ^ Function to get the next message.
  , __getMessage       :: IO mt

    -- ^ Function to log a debug message (no newline).
  , __debugPrint       :: nt -> String -> IO ()
  }

data Role = Follower
          | Candidate
          | Leader
  deriving (Show, Generic, Eq)

data Event nt et rt = ERPC (RPC nt et rt)
                    | ElectionTimeout String
                    | HeartbeatTimeout String
  deriving (Show)

-- | A version of RaftSpec where all IO functions are lifted
-- into the Raft monad.
data LiftedRaftSpec nt et rt mt t = LiftedRaftSpec
  {
    -- ^ Function to get a log entry from persistent storage.
    _readLogEntry     :: MonadTrans t => LogIndex -> t IO (Maybe et)

    -- ^ Function to write a log entry to persistent storage.
  , _writeLogEntry    :: MonadTrans t => LogIndex -> (Term,et) -> t IO ()

    -- ^ Function to get the term number from persistent storage.
  , _readTermNumber   :: MonadTrans t => t IO Term

    -- ^ Function to write the term number to persistent storage.
  , _writeTermNumber  :: MonadTrans t => Term -> t IO ()

    -- ^ Function to read the node voted for from persistent storage.
  , _readVotedFor     :: MonadTrans t => t IO (Maybe nt)

    -- ^ Function to write the node voted for to persistent storage.
  , _writeVotedFor    :: MonadTrans t => Maybe nt -> t IO ()

    -- ^ Function to apply a log entry to the state machine.
  , _applyLogEntry    :: MonadTrans t => et -> t IO rt

    -- ^ Function to serialize an RPC.
  , _serializeRPC     :: RPC nt et rt -> mt

    -- ^ Function to deserialize an RPC.
  , _deserializeRPC   :: mt -> Maybe (RPC nt et rt)

    -- ^ Function to send a message to a node.
  , _sendMessage      :: MonadTrans t => nt -> mt -> t IO ()

    -- ^ Function to get the next message.
  , _getMessage       :: MonadTrans t => t IO mt

    -- ^ Function to log a debug message (no newline).
  , _debugPrint       :: nt -> String -> t IO ()
  }
makeLenses ''LiftedRaftSpec

liftRaftSpec :: MonadTrans t => RaftSpec nt et rt mt -> LiftedRaftSpec nt et rt mt t
liftRaftSpec RaftSpec{..} =
  LiftedRaftSpec
    { _readLogEntry    = lift . __readLogEntry
    , _writeLogEntry   = \i et -> lift (__writeLogEntry i et)
    , _readTermNumber  = lift __readTermNumber
    , _writeTermNumber = lift . __writeTermNumber
    , _readVotedFor    = lift __readVotedFor
    , _writeVotedFor   = lift . __writeVotedFor
    , _applyLogEntry   = lift . __applyLogEntry
    , _serializeRPC    = __serializeRPC
    , _deserializeRPC  = __deserializeRPC
    , _sendMessage     = \n m -> lift (__sendMessage n m)
    , _getMessage      = lift __getMessage
    , _debugPrint      = \n s -> lift (__debugPrint n s)
    }

data RaftState nt et = RaftState
  { _role            :: Role
  , _term            :: Term
  , _votedFor        :: Maybe nt
  , _currentLeader   :: Maybe nt
  , _logEntries      :: Seq (Term, Command nt et)
  , _commitIndex     :: LogIndex
  , _lastApplied     :: LogIndex
  , _timerThread     :: Maybe ThreadId
  , _cYesVotes       :: Set nt
  , _cPotentialVotes :: Set nt
  , _lNextIndex      :: Map nt LogIndex
  , _lMatchIndex     :: Map nt LogIndex
  , _pendingRequests :: Map RequestId (Command nt et) -- used by clients
  , _nextRequestId   :: RequestId                     -- used by clients
  }
makeLenses ''RaftState

initialRaftState :: RaftState nt et
initialRaftState = RaftState
  Follower   -- role
  startTerm  -- term
  Nothing    -- votedFor
  Nothing    -- currentLeader
  Seq.empty  -- log
  startIndex -- commitIndex
  startIndex -- lastApplied
  Nothing    -- timerThread
  Set.empty  -- cYesVotes
  Set.empty  -- cPotentialVotes
  Map.empty  -- lNextIndex
  Map.empty  -- lMatchIndex
  Map.empty  -- pendingRequests
  0          -- nextRequestId

data RaftEnv nt et rt mt = RaftEnv
  { _cfg        :: Config nt
  , _quorumSize :: Int
  , _eventIn    :: InChan (Event nt et rt)
  , _eventOut   :: OutChan (Event nt et rt)
  , _rs         :: LiftedRaftSpec nt et rt mt (RWST (RaftEnv nt et rt mt) () (RaftState nt et))
  }
makeLenses ''RaftEnv

type Raft nt et rt mt a = RWST (RaftEnv nt et rt mt) () (RaftState nt et) IO a

instance Binary Term
instance Binary RequestId

instance (Binary nt, Binary et) => Binary (AppendEntries nt et)
instance Binary nt              => Binary (AppendEntriesResponse nt)
instance Binary nt              => Binary (RequestVote nt)
instance Binary nt              => Binary (RequestVoteResponse nt)
instance (Binary nt, Binary et) => Binary (Command nt et)
instance (Binary nt, Binary rt) => Binary (CommandResponse nt rt)

instance (Binary nt, Binary et, Binary rt) => Binary (RPC nt et rt)
