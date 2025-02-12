module Morphir.Elm.Target exposing (..)

import Json.Decode as Decode exposing (Error, Value)
import Morphir.File.FileMap exposing (FileMap)
import Morphir.Graph.Backend.Codec
import Morphir.Graph.CypherBackend as Cypher
import Morphir.Graph.SemanticBackend as SemanticBackend
import Morphir.IR.Distribution exposing (Distribution)
import Morphir.IR.Package as Package
import Morphir.Scala.Backend
import Morphir.Scala.Backend.Codec
import Morphir.SpringBoot.Backend as SpringBoot
import Morphir.SpringBoot.Backend.Codec


import Morphir.Graph.SemanticBackend as SemanticBackend
import Morphir.Graph.CypherBackend as Cypher
import Morphir.Graph.Backend.Codec
import Morphir.TypeScript.Backend
import Morphir.TypeScript.Backend.Codec

-- possible language generation options


type BackendOptions
    = ScalaOptions Morphir.Scala.Backend.Options
    | SpringBootOptions Morphir.Scala.Backend.Options
    | SemanticOptions Morphir.Scala.Backend.Options
    | CypherOptions Morphir.Scala.Backend.Options
    | TypeScriptOptions Morphir.TypeScript.Backend.Options


decodeOptions : Result Error String -> Decode.Decoder BackendOptions
decodeOptions gen =
    case gen of
        Ok "SpringBoot" ->
            Decode.map (\options -> SpringBootOptions options) Morphir.SpringBoot.Backend.Codec.decodeOptions

        Ok "semantic" ->
            Decode.map (\options -> SemanticOptions options) Morphir.Graph.Backend.Codec.decodeOptions

        Ok "cypher" ->
            Decode.map (\options -> CypherOptions options) Morphir.Graph.Backend.Codec.decodeOptions

        Ok "TypeScript" ->
            Decode.map (\(options) -> TypeScriptOptions(options)) Morphir.Graph.Backend.Codec.decodeOptions

        _ ->
            Decode.map (\options -> ScalaOptions options) Morphir.Scala.Backend.Codec.decodeOptions


mapDistribution : BackendOptions -> Distribution -> FileMap
mapDistribution back dist =
    case back of
        SpringBootOptions options ->
            SpringBoot.mapDistribution options dist

        SemanticOptions options ->
            SemanticBackend.mapDistribution options dist

        CypherOptions options ->
            Cypher.mapDistribution options dist

        ScalaOptions options ->
            Morphir.Scala.Backend.mapDistribution options dist

        TypeScriptOptions options ->
            Morphir.TypeScript.Backend.mapDistribution options dist
