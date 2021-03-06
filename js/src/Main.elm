port module Main exposing (main)

-- Mapping Corona virus infections in NSW, Australia
-- Toolbox for open layers map with clustering features
-- Thomas Paine, 2020

import Browser
import Html exposing (Html, text, div, input, label, button, option, select, p, strong)
import Html.Attributes exposing (class, type_, placeholder, value, checked, id, attribute, style)
import Html.Events exposing (onClick, onInput, onCheck)
import Time exposing (Posix, posixToMillis, millisToPosix)
import Json.Decode exposing (Decoder, field, string, list, at, int, dict, maybe)
import Json.Encode exposing (encode, object)
import Http exposing (Error)
import Dict exposing (Dict)
import Iso8601 exposing (toTime, fromTime)

-- Communicate postcode from open layers js
port subPostcode : (String -> msg) -> Sub msg

main = Browser.element
    { init = init
    , update = update
    , subscriptions = subscriptions
    , view = view
    }

type Msg = IncDate Int
         | StartTimeline
         | JsonResponse (Result Http.Error (List Properties))
         | CheckDate String
         | CheckPostcode String
         | CheckSources String Bool
         | UpdateDate String
         | ToggleControls
         | Hover String

type alias Model =
    { dates:
          { date : Posix
          , minDate : Posix
          , maxDate : Posix
          }
    , numDays : Maybe Int
    , sources : Dict String Bool
    , filtered : Dict String Int
    , unfiltered : List Properties
    , postcode : String
    , dateVal : String
    , isTimer : Bool
    , hideControls : Bool
    }

init : Int -> (Model, Cmd Msg)
init v =
  ( Model { date = Time.millisToPosix 0
          , minDate = Time.millisToPosix 0
          , maxDate = Time.millisToPosix 0}
        Nothing Dict.empty Dict.empty [] "" "" False False
  , Cmd.batch [ Http.get
                   { url = "./geo.json?" ++ String.fromInt v
                   , expect = Http.expectJson JsonResponse geoDecoder}
              ]
  )

-- Single GeoJson row
type alias Properties =
    { postcode : String
    , infections : Dict String (Dict String Int) -- date, infection type, infection count
    , tests : Int
    }

geoDecoder = field "features"
             <| list (Json.Decode.map3 Properties
                          (field "properties"
                               <| field "postcode" string)
                          (field "properties"
                               <| field "infections" <| dict <| dict <| int)
                          (field "properties"
                               <| field "tests" <| int))

update : Msg -> Model -> (Model, Cmd Msg)
update msg model =
    let dates = model.dates in
    case msg of
        -- Plus or minus one day
        IncDate sign -> let newDate = incDay dates sign in
                        ({ model
                             | dates = { dates | date = newDate }
                             , dateVal = String.left 10 (fromTime newDate)
                             , isTimer = if model.isTimer && newDate == dates.maxDate
                                           then False
                                           else model.isTimer }
                             |> refilter
                        , Cmd.none)
        -- Toggle whether timeline is running
        StartTimeline -> (if not model.isTimer && model.dates.date == model.dates.maxDate
                         then { model
                                  | isTimer = not model.isTimer,
                                    dates = { dates | date = millisToPosix <| posixToMillis model.dates.minDate +
                                                  (Maybe.withDefault 0 model.numDays)*86400000} }
                             |> refilter
                         else { model | isTimer = not model.isTimer }
                        , Cmd.none)
        -- Fetch GeoJson from file
        JsonResponse result ->
            case Result.toMaybe result of
                Nothing -> (model, Cmd.none)
                Just geoJson ->
                    (let newMax = maxDate geoJson
                     in {model
                            | unfiltered = geoJson
                            , sources = infectionTypes geoJson
                            , dates = { dates
                                          | minDate = minDate geoJson
                                          , maxDate = newMax
                                          , date = newMax }
                            , dateVal = String.left 10 <| fromTime newMax }
                         |> refilter
                    , Cmd.none)
        -- Check if date input matches "yyyy-mm-dd"
        CheckDate string -> case Result.toMaybe <| toTime string of
                                Nothing -> ({model | dateVal = string}
                                           , Cmd.none)
                                Just posix -> ({model
                                                   | dates = { dates | date = posix}
                                                   , dateVal = string }
                                                   |> refilter
                                              , Cmd.none)
        -- Store postcode input
        CheckPostcode postcode -> ({model | postcode = postcode }, Cmd.none)
        -- Filter by infectuib source
        CheckSources name bool -> ({model | sources = Dict.insert name bool model.sources} |> refilter, Cmd.none)
        --
        UpdateDate val -> ( { model | numDays = String.toInt val} |> refilter
                          , Cmd.none)
        ToggleControls -> ({ model | hideControls = not model.hideControls}, Cmd.none)
        Hover postcode -> ({ model | postcode = postcode }, Cmd.none)

--
refilter : Model -> Model
refilter model =
    let newFilter = List.foldl checkProps Dict.empty model.unfiltered
        checkProps prop result1 = Dict.insert prop.postcode (Dict.foldl checkDates 0 prop.infections) result1
        checkDates date infs result2 =
            case toTime date |> Result.toMaybe of
                Nothing -> result2
                Just posix -> if posixToMillis posix > (case model.numDays of
                                                            Nothing -> posixToMillis model.dates.minDate
                                                            Just num -> posixToMillis model.dates.date  - num * 86400000)
                              && posixToMillis posix <= posixToMillis model.dates.date
                              then Dict.foldl checkLast result2 infs
                              else result2
        checkLast inf num result3 = if Dict.isEmpty model.sources
                                    || case Dict.get inf model.sources of
                                           Just v -> v
                                           Nothing -> False
                                    then num + result3
                                    else result3
    in { model
           | filtered = newFilter }

-- Watch postcode from port and increment date if timeline is running
subscriptions : Model -> Sub Msg
subscriptions model = if model.isTimer
                      then Sub.batch [subPostcode Hover, always (IncDate 1) |> Time.every 1000]
                      else subPostcode Hover


jsonEncode val = encode 0 <| object <| Dict.toList <| Dict.map (\_ -> Json.Encode.int) val

view : Model -> Html Msg
view model =
    let postcodeCheck = List.any (\p -> model.postcode == p.postcode) model.unfiltered
    in div []
        [ button (if model.hideControls
                  then [class "button", onClick ToggleControls]
                  else [class "button", onClick ToggleControls, style "display" "none"]) [text "Show Controls"]
        , div (if model.hideControls
               then [id "filtered_json", attribute "data-json" (jsonEncode model.filtered), style "display" "none"]
               else [id "filtered_json", attribute "data-json" (jsonEncode model.filtered)])
            [ formField "Controls" [button [class "button", onClick ToggleControls] [text "Hide Controls"]]
            , div [class "box field has-addons"]
                [ div [class "control"] [button [class "button is-dark", onClick (IncDate -1)] [text "Prev"]]
                , div [class "control"] [input [ case toTime model.dateVal |> Result.toMaybe of
                                                     Nothing -> class "input is-danger"
                                                     Just _ -> class "input"
                                               , type_ "text"
                                               , onInput CheckDate
                                               , value model.dateVal] []]
                , div [class "control"] [button [class "button is-dark", onClick (IncDate 1)] [text "Next"]]
                ]
            , formField "Timeline" [if model.isTimer
                                    then timerButton "Stop" "button is-warning"
                                    else timerButton "Start" "button is-danger"]
            , formField "Cases in last 'x' number of days" [div [class "select"] [select [onInput UpdateDate] (manyOptions model.dates)]]
            , formField "Filter" (List.map formCheckbox <| Dict.toList model.sources)
            , formField "Postcode" [input [ if model.postcode == "" then class "input"
                                            else if postcodeCheck
                                                 then class "input is-success"
                                                 else class "input is-danger"
                                          , type_ "text"
                                          , onInput CheckPostcode
                                          , placeholder "Postcode"
                                          , value model.postcode] []]
            , if postcodeCheck
              then postcodeDetails model.postcode model.unfiltered
              else div [] []
            ]
        ]

manyOptions dates =
    let numOpts = (posixToMillis dates.date - posixToMillis dates.minDate) // 86400000 + 1
        optionsTill num = if num > numOpts
                          then []
                          else option [] [num |> String.fromInt |> text] :: (optionsTill <| num + 1)
    in option [] [text "any"] :: (optionsTill 1)

infectionTypes data =
    let checkProps prop result1 = Dict.foldl checkDates result1 prop.infections
        checkDates date infs result2 = Dict.foldl checkLast result2 infs
        checkLast inf num result3 = if Dict.member inf result3
                                    then result3
                                    else Dict.insert inf True result3
    in List.foldl checkProps Dict.empty data

minDate data = timeParse List.minimum data

maxDate data = timeParse List.maximum data

timeParse f data = List.map (\p -> p.infections
                        |> Dict.keys |> List.map (\v -> Result.toMaybe <| toTime v)
                        ) data
             |> List.concat |> List.filterMap (Maybe.map posixToMillis)
             |> f |> Maybe.withDefault 0 |> millisToPosix

showProp property = p [] [text property.postcode]

postcodeDetails postcode properties =
    let datePrint date val = div [] <| strong [] [text date] :: (Dict.values <| Dict.map infPrint val)
        infPrint inf num = p [] [inf ++ ": " |> text, strong [] [String.fromInt num |> text]]
        infectionSum infs = List.sum <| List.map List.sum <| Dict.values <| Dict.map (\_ -> Dict.values) infs
        showTests tests cases = div []
                               [ p [] [strong [] [text "Tests: "], String.fromInt tests |> text]
                               , p [] [strong [] [text "Cases: "], String.fromInt cases |> text]
                               , p []
                                   [ strong [] [text "Cases/Tests: "]
                                   , (String.slice 0 5 <| String.fromFloat
                                         <| 100 * toFloat cases / toFloat tests) ++ "%" |> text]
                              ]
    in case List.head <| List.filter (\p -> postcode == p.postcode) properties of
        Nothing -> div [] []
        Just prop -> div [class "box"] [showTests prop.tests <| infectionSum prop.infections, div [] (List.reverse <| Dict.values <| Dict.map datePrint prop.infections)]

timerButton name classes = button [class classes, onClick StartTimeline] [text name]

formField name htmls = div [class "field box"]
                       [ label [class "label"] [text name]
                       , div [class "control"] htmls]

formCheckbox (description, checke) = div [class "field"]
                          [ div [class "control"]
                                [ label [class "checkbox"]
                                      [input [type_ "checkbox", checked checke, onCheck <| CheckSources description] []
                                      , text description]]]

-- Add or subtract one day from dates.date
incDay dates sign = let maxM = posixToMillis dates.maxDate
                        minM = posixToMillis dates.minDate
                        newDayM = posixToMillis dates.date + sign * 86400000
                    -- check bounds as posix
                    in if newDayM > maxM then millisToPosix maxM
                       else if newDayM < minM then millisToPosix minM
                            else millisToPosix newDayM
