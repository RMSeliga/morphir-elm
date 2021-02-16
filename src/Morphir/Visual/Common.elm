module Morphir.Visual.Common exposing (cssClass, definition, element, grayScale, nameToText)

import Element exposing (Attribute, Color, Element, column, el, height, paddingEach, rgb, row, shrink, spacing, text, width)
import Element.Font as Font
import Html exposing (Html)
import Html.Attributes exposing (class)
import Morphir.IR.Name as Name exposing (Name)
import Morphir.Visual.Config exposing (Config)


cssClass : String -> Attribute msg
cssClass className =
    Element.htmlAttribute (class className)


nameToText : Name -> String
nameToText name =
    name
        |> Name.toHumanWords
        |> String.join " "


element : Element msg -> Html msg
element elem =
    Element.layoutWith
        { options =
            [ Element.noStaticStyleSheet
            ]
        }
        [ width shrink
        , height shrink
        ]
        elem


grayScale : Float -> Color
grayScale v =
    rgb v v v


definition : Config msg -> String -> Element msg -> Element msg
definition config header body =
    column [ spacing config.state.theme.mediumSpacing ]
        [ row [ spacing config.state.theme.mediumSpacing ]
            [ el [ Font.bold ] (text header)
            , el [] (text "=")
            ]
        , el [ paddingEach { left = config.state.theme.mediumPadding, right = 0, top = 0, bottom = 0 } ]
            body
        ]
