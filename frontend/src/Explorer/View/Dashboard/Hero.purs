module Explorer.View.Dashboard.Hero
    (heroView
    ) where

import Prelude
import Data.Lens ((^.))
import Explorer.I18n.Lang (translate)
import Explorer.I18n.Lenses (common, hero, cTitle, hrSubtitle) as I18nL
import Explorer.Lenses.State (lang)
import Explorer.State (heroSearchContainerId)
import Explorer.Types.Actions (Action)
import Explorer.Types.State (State)
import Explorer.View.Common (logoView)
import Explorer.View.Search (searchInputView)
import Pux.Html (Html, div, text, h1, h2) as P
import Pux.Html.Attributes (className, id_) as P

heroView :: State -> P.Html Action
heroView state =
    let
        lang' = state ^. lang
    in
    P.div
        [ P.className "explorer-dashboard__hero"
        , P.id_ "explorer-dashboard__hero-id"
        ]
        [ P.div
            [ P.className "hero-container" ]
            [ logoView
            , P.h1
                [ P.className "hero-headline" ]
                [ P.text $ translate (I18nL.common <<< I18nL.cTitle) lang' ]
            , P.h2
                [ P.className "hero-subheadline"]
                [ P.text $ translate (I18nL.hero <<< I18nL.hrSubtitle) lang' ]
            , searchInputView heroSearchContainerId state
            ]
        ]
