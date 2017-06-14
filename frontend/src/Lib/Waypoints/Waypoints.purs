module Waypoints where

import Prelude
import Control.Monad.Eff (Eff)
import DOM.Node.Types (ElementId)
import Data.Function.Eff (EffFn3, runEffFn3)
import Data.Function.Uncurried (Fn1)
import Data.Generic (class Generic, gShow)
import Data.Newtype (class Newtype)

foreign import data WAYPOINT :: !
foreign import data Waypoint :: *

type WaypointHandler eff = WaypointDirection -> Eff (waypoint :: WAYPOINT | eff) Unit

type WaypointOffset = Int

defaultWaypointOffset :: WaypointOffset
defaultWaypointOffset = 0

newtype WaypointDirection = WaypointDirection String

derive instance gWaypointDirection :: Generic WaypointDirection
derive instance ntWaypointDirection :: Newtype WaypointDirection _
derive instance eqWaypointDirection :: Eq WaypointDirection
instance sWaypointDirection :: Show WaypointDirection where
    show = gShow

up :: WaypointDirection
up = WaypointDirection "up"

down :: WaypointDirection
down = WaypointDirection "down"

foreign import waypointImpl :: forall eff. EffFn3 (waypoint :: WAYPOINT | eff) ElementId (WaypointHandler eff) WaypointOffset Waypoint

-- | Initializes a `Waypoint`
waypoint :: forall eff. ElementId -> (WaypointHandler eff) -> Eff (waypoint :: WAYPOINT | eff) Waypoint
waypoint elemId handler = runEffFn3 waypointImpl elemId handler defaultWaypointOffset

-- | Initializes a `Waypoint` with an offset
waypoint' :: forall eff. ElementId -> (WaypointHandler eff) -> WaypointOffset -> Eff (waypoint :: WAYPOINT | eff) Waypoint
waypoint' = runEffFn3 waypointImpl

foreign import destroy :: forall eff. Fn1 Waypoint (Eff (waypoint :: WAYPOINT | eff) Unit)
