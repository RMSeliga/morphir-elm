module Morphir.Type.Infer exposing (..)

import Dict exposing (Dict)
import Morphir.IR.AccessControlled exposing (AccessControlled)
import Morphir.IR.FQName exposing (FQName(..))
import Morphir.IR.Literal exposing (Literal(..))
import Morphir.IR.Module as Module exposing (ModuleName)
import Morphir.IR.Name as Name exposing (Name)
import Morphir.IR.Package as Package exposing (PackageName)
import Morphir.IR.Type as Type exposing (Specification(..), Type)
import Morphir.IR.Value as Value exposing (Pattern(..), Value)
import Morphir.ListOfResults as ListOfResults
import Morphir.Type.Class as Class exposing (Class)
import Morphir.Type.Constraint as Constraint exposing (Constraint(..), class, equality)
import Morphir.Type.ConstraintSet as ConstraintSet exposing (ConstraintSet(..))
import Morphir.Type.MetaType as MetaType exposing (MetaType(..), Variable)
import Morphir.Type.MetaTypeMapping exposing (LookupError, References, concreteTypeToMetaType, concreteVarsToMetaVars, ctorToMetaType, lookupAliasedType, lookupConstructor, lookupValue, metaTypeToConcreteType, valueSpecToMetaType)
import Morphir.Type.SolutionMap as SolutionMap exposing (SolutionMap(..))
import Set exposing (Set)


type alias TypedValue va =
    Value () ( va, Type () )


type ValueTypeError
    = ValueTypeError Name TypeError


type TypeError
    = TypeErrors (List TypeError)
    | ClassConstraintViolation MetaType Class
    | LookupError LookupError
    | UnknownError String
    | CouldNotUnify UnificationError MetaType MetaType


type UnificationError
    = NoUnificationRule
    | TuplesOfDifferentSize
    | RefMismatch
    | FieldMismatch


inferPackageDefinition : References -> Package.Definition ta va -> Result (List ValueTypeError) (Package.Definition ta ( va, Type () ))
inferPackageDefinition refs packageDef =
    packageDef.modules
        |> Dict.toList
        |> List.map
            (\( moduleName, moduleDef ) ->
                inferModuleDefinition refs moduleDef.value
                    |> Result.map (AccessControlled moduleDef.access)
                    |> Result.map (Tuple.pair moduleName)
            )
        |> ListOfResults.liftAllErrors
        |> Result.map
            (\mappedModules ->
                { modules = Dict.fromList mappedModules
                }
            )
        |> Result.mapError List.concat


inferModuleDefinition : References -> Module.Definition ta va -> Result (List ValueTypeError) (Module.Definition ta ( va, Type () ))
inferModuleDefinition refs moduleDef =
    moduleDef.values
        |> Dict.toList
        |> List.map
            (\( valueName, valueDef ) ->
                inferValueDefinition refs valueDef.value
                    |> Result.map (AccessControlled valueDef.access)
                    |> Result.map (Tuple.pair valueName)
                    |> Result.mapError (ValueTypeError valueName)
            )
        |> ListOfResults.liftAllErrors
        |> Result.map
            (\mappedValues ->
                { types = moduleDef.types
                , values = Dict.fromList mappedValues
                }
            )


inferValueDefinition : References -> Value.Definition ta va -> Result TypeError (Value.Definition ta ( va, Type () ))
inferValueDefinition refs def =
    let
        ( annotatedDef, lastVarIndex ) =
            annotateDefinition 0 def

        constraints : ConstraintSet
        constraints =
            constrainDefinition (MetaType.variable 0) Dict.empty annotatedDef

        solution : Result TypeError ( ConstraintSet, SolutionMap )
        solution =
            solve (MetaType.variable (lastVarIndex + 1)) refs constraints
    in
    solution
        |> Result.map (applySolutionToAnnotatedDefinition annotatedDef)


inferValue : References -> Value () va -> Result TypeError (TypedValue va)
inferValue refs untypedValue =
    let
        ( annotatedValue, lastVarIndex ) =
            annotateValue 0 untypedValue

        constraints : ConstraintSet
        constraints =
            constrainValue Dict.empty annotatedValue

        solution : Result TypeError ( ConstraintSet, SolutionMap )
        solution =
            solve (MetaType.variable (lastVarIndex + 1)) refs constraints
    in
    solution
        |> Result.map (applySolutionToAnnotatedValue annotatedValue)


annotateDefinition : Int -> Value.Definition ta va -> ( Value.Definition ta ( va, Variable ), Int )
annotateDefinition baseIndex def =
    let
        annotatedInputTypes : List ( Name, ( va, Variable ), Type ta )
        annotatedInputTypes =
            def.inputTypes
                |> List.indexedMap
                    (\index ( name, va, tpe ) ->
                        ( name, ( va, MetaType.variable (baseIndex + index) ), tpe )
                    )

        ( annotatedBody, lastVarIndex ) =
            annotateValue (baseIndex + List.length def.inputTypes) def.body
    in
    ( { inputTypes =
            annotatedInputTypes
      , outputType =
            def.outputType
      , body =
            annotatedBody
      }
    , lastVarIndex
    )


annotateValue : Int -> Value ta va -> ( Value ta ( va, Variable ), Int )
annotateValue baseIndex untypedValue =
    untypedValue
        |> Value.indexedMapValue (\index va -> ( va, MetaType.variable index )) baseIndex


constrainDefinition : Variable -> Dict Name Variable -> Value.Definition ta ( va, Variable ) -> ConstraintSet
constrainDefinition baseVar vars def =
    let
        inputTypeVars : Set Name
        inputTypeVars =
            def.inputTypes
                |> List.map
                    (\( _, _, declaredType ) ->
                        Type.collectVariables declaredType
                    )
                |> List.foldl Set.union Set.empty

        outputTypeVars : Set Name
        outputTypeVars =
            Type.collectVariables def.outputType

        varToMeta : Dict Name Variable
        varToMeta =
            concreteVarsToMetaVars baseVar
                (Set.union inputTypeVars outputTypeVars)

        inputConstraints : ConstraintSet
        inputConstraints =
            def.inputTypes
                |> List.map
                    (\( _, ( _, thisTypeVar ), declaredType ) ->
                        equality
                            (MetaVar thisTypeVar)
                            (concreteTypeToMetaType thisTypeVar varToMeta declaredType)
                    )
                |> ConstraintSet.fromList

        outputConstraints : ConstraintSet
        outputConstraints =
            ConstraintSet.singleton
                (equality
                    (metaTypeVarForValue def.body)
                    (concreteTypeToMetaType baseVar varToMeta def.outputType)
                )

        inputVars : Dict Name Variable
        inputVars =
            def.inputTypes
                |> List.map
                    (\( name, ( _, thisTypeVar ), _ ) ->
                        ( name, thisTypeVar )
                    )
                |> Dict.fromList

        bodyConstraints : ConstraintSet
        bodyConstraints =
            constrainValue (vars |> Dict.union inputVars) def.body
    in
    ConstraintSet.concat
        [ inputConstraints
        , outputConstraints
        , bodyConstraints
        ]


constrainValue : Dict Name Variable -> Value ta ( va, Variable ) -> ConstraintSet
constrainValue vars annotatedValue =
    case annotatedValue of
        Value.Literal ( _, thisTypeVar ) literalValue ->
            constrainLiteral thisTypeVar literalValue

        Value.Constructor ( _, thisTypeVar ) fQName ->
            ConstraintSet.singleton
                (Constraint.lookupConstructor (MetaVar thisTypeVar) fQName)

        Value.Tuple ( _, thisTypeVar ) elems ->
            let
                elemsConstraints : List ConstraintSet
                elemsConstraints =
                    elems
                        |> List.map (constrainValue vars)

                tupleConstraint : ConstraintSet
                tupleConstraint =
                    ConstraintSet.singleton
                        (equality
                            (MetaVar thisTypeVar)
                            (elems
                                |> List.map metaTypeVarForValue
                                |> MetaTuple
                            )
                        )
            in
            ConstraintSet.concat (tupleConstraint :: elemsConstraints)

        Value.List ( _, thisTypeVar ) items ->
            let
                itemType : MetaType
                itemType =
                    MetaVar (thisTypeVar |> MetaType.subVariable)

                listConstraint : Constraint
                listConstraint =
                    equality (MetaVar thisTypeVar) (MetaType.listType itemType)

                itemConstraints : ConstraintSet
                itemConstraints =
                    items
                        |> List.map
                            (\item ->
                                constrainValue vars item
                                    |> ConstraintSet.insert (equality (metaTypeVarForValue item) itemType)
                            )
                        |> ConstraintSet.concat
            in
            itemConstraints
                |> ConstraintSet.insert listConstraint

        Value.Record ( _, thisTypeVar ) fieldValues ->
            let
                fieldConstraints : ConstraintSet
                fieldConstraints =
                    fieldValues
                        |> List.map (Tuple.second >> constrainValue vars)
                        |> ConstraintSet.concat

                recordType : MetaType
                recordType =
                    fieldValues
                        |> List.map
                            (\( fieldName, fieldValue ) ->
                                ( fieldName, metaTypeVarForValue fieldValue )
                            )
                        |> Dict.fromList
                        |> MetaRecord Nothing

                recordConstraints : ConstraintSet
                recordConstraints =
                    ConstraintSet.singleton
                        (equality (MetaVar thisTypeVar) recordType)
            in
            ConstraintSet.concat
                [ fieldConstraints
                , recordConstraints
                ]

        Value.Variable ( _, varUse ) varName ->
            case vars |> Dict.get varName of
                Just varDecl ->
                    ConstraintSet.singleton (equality (MetaVar varUse) (MetaVar varDecl))

                Nothing ->
                    -- this should never happen if variables were validated earlier
                    ConstraintSet.empty

        Value.Reference ( _, thisTypeVar ) fQName ->
            ConstraintSet.singleton
                (Constraint.lookupValue (MetaVar thisTypeVar) fQName)

        Value.Field ( _, thisTypeVar ) subjectValue fieldName ->
            let
                extendsVar : Variable
                extendsVar =
                    thisTypeVar
                        |> MetaType.subVariable

                fieldType : MetaType
                fieldType =
                    extendsVar
                        |> MetaType.subVariable
                        |> MetaVar

                extensibleRecordType : MetaType
                extensibleRecordType =
                    MetaRecord (Just extendsVar)
                        (Dict.singleton fieldName fieldType)

                fieldConstraints : ConstraintSet
                fieldConstraints =
                    ConstraintSet.fromList
                        [ equality (metaTypeVarForValue subjectValue) extensibleRecordType
                        , equality (MetaVar thisTypeVar) fieldType
                        ]
            in
            ConstraintSet.concat
                [ constrainValue vars subjectValue
                , fieldConstraints
                ]

        Value.FieldFunction ( _, thisTypeVar ) fieldName ->
            let
                extendsVar : Variable
                extendsVar =
                    thisTypeVar
                        |> MetaType.subVariable

                fieldType : MetaType
                fieldType =
                    extendsVar
                        |> MetaType.subVariable
                        |> MetaVar

                extensibleRecordType : MetaType
                extensibleRecordType =
                    MetaRecord (Just extendsVar)
                        (Dict.singleton fieldName fieldType)
            in
            ConstraintSet.singleton
                (equality (MetaVar thisTypeVar) (MetaFun extensibleRecordType fieldType))

        Value.Apply ( _, thisTypeVar ) funValue argValue ->
            let
                funType : MetaType
                funType =
                    MetaFun
                        (metaTypeVarForValue argValue)
                        (MetaVar thisTypeVar)

                applyConstraints : ConstraintSet
                applyConstraints =
                    ConstraintSet.singleton
                        (equality (metaTypeVarForValue funValue) funType)
            in
            ConstraintSet.concat
                [ constrainValue vars funValue
                , constrainValue vars argValue
                , applyConstraints
                ]

        Value.Lambda ( _, thisTypeVar ) argPattern bodyValue ->
            let
                ( argVariables, argConstraints ) =
                    constrainPattern argPattern

                lambdaType : MetaType
                lambdaType =
                    MetaFun
                        (metaTypeVarForPattern argPattern)
                        (metaTypeVarForValue bodyValue)

                lambdaConstraints : ConstraintSet
                lambdaConstraints =
                    ConstraintSet.singleton
                        (equality (MetaVar thisTypeVar) lambdaType)
            in
            ConstraintSet.concat
                [ lambdaConstraints
                , constrainValue (Dict.union argVariables vars) bodyValue
                , argConstraints
                ]

        Value.LetDefinition ( _, thisTypeVar ) defName def inValue ->
            let
                defConstraints : ConstraintSet
                defConstraints =
                    constrainDefinition thisTypeVar vars def

                defTypeVar : Variable
                defTypeVar =
                    thisTypeVar |> MetaType.subVariable

                defType : List MetaType -> MetaType -> MetaType
                defType argTypes returnType =
                    case argTypes of
                        [] ->
                            returnType

                        firstArg :: restOfArgs ->
                            MetaFun firstArg (defType restOfArgs returnType)

                inConstraints : ConstraintSet
                inConstraints =
                    constrainValue
                        (vars
                            |> Dict.insert defName defTypeVar
                        )
                        inValue

                letConstraints : ConstraintSet
                letConstraints =
                    ConstraintSet.fromList
                        [ equality (MetaVar thisTypeVar) (metaTypeVarForValue inValue)
                        , equality (MetaVar defTypeVar)
                            (defType
                                (def.inputTypes |> List.map (\( _, ( _, argTypeVar ), _ ) -> MetaVar argTypeVar))
                                (metaTypeVarForValue def.body)
                            )
                        ]
            in
            ConstraintSet.concat
                [ defConstraints
                , inConstraints
                , letConstraints
                ]

        Value.LetRecursion ( _, thisTypeVar ) defs inValue ->
            let
                defType : List MetaType -> MetaType -> MetaType
                defType argTypes returnType =
                    case argTypes of
                        [] ->
                            returnType

                        firstArg :: restOfArgs ->
                            MetaFun firstArg (defType restOfArgs returnType)

                ( lastDefTypeVar, defDeclsConstraints, defVariables ) =
                    defs
                        |> Dict.toList
                        |> List.foldl
                            (\( defName, def ) ( lastTypeVar, constraintsSoFar, variablesSoFar ) ->
                                let
                                    nextTypeVar : Variable
                                    nextTypeVar =
                                        lastTypeVar |> MetaType.subVariable

                                    letConstraint : ConstraintSet
                                    letConstraint =
                                        ConstraintSet.fromList
                                            [ equality (MetaVar nextTypeVar)
                                                (defType
                                                    (def.inputTypes |> List.map (\( _, ( _, argTypeVar ), _ ) -> MetaVar argTypeVar))
                                                    (metaTypeVarForValue def.body)
                                                )
                                            ]
                                in
                                ( nextTypeVar, letConstraint :: constraintsSoFar, ( defName, nextTypeVar ) :: variablesSoFar )
                            )
                            ( thisTypeVar, [], [] )

                defsConstraints =
                    defs
                        |> Dict.toList
                        |> List.foldl
                            (\( _, def ) ( lastTypeVar, constraintsSoFar ) ->
                                let
                                    nextTypeVar : Variable
                                    nextTypeVar =
                                        lastTypeVar |> MetaType.subVariable

                                    defConstraints : ConstraintSet
                                    defConstraints =
                                        constrainDefinition lastTypeVar vars def
                                in
                                ( nextTypeVar, defConstraints :: constraintsSoFar )
                            )
                            ( lastDefTypeVar, defDeclsConstraints )
                        |> Tuple.second
                        |> ConstraintSet.concat

                inConstraints : ConstraintSet
                inConstraints =
                    constrainValue
                        (vars
                            |> Dict.union (defVariables |> Dict.fromList)
                        )
                        inValue

                letConstraints : ConstraintSet
                letConstraints =
                    ConstraintSet.fromList
                        [ equality (MetaVar thisTypeVar) (metaTypeVarForValue inValue)
                        ]
            in
            ConstraintSet.concat
                [ defsConstraints
                , inConstraints
                , letConstraints
                ]

        Value.Destructure ( _, thisTypeVar ) bindPattern bindValue inValue ->
            let
                ( bindPatternVariables, bindPatternConstraints ) =
                    constrainPattern bindPattern

                bindValueConstraints : ConstraintSet
                bindValueConstraints =
                    constrainValue vars bindValue

                inValueConstraints : ConstraintSet
                inValueConstraints =
                    constrainValue (Dict.union bindPatternVariables vars) inValue

                destructureConstraints : ConstraintSet
                destructureConstraints =
                    ConstraintSet.fromList
                        [ equality (MetaVar thisTypeVar) (metaTypeVarForValue inValue)
                        , equality (metaTypeVarForValue bindValue) (metaTypeVarForPattern bindPattern)
                        ]
            in
            ConstraintSet.concat
                [ bindPatternConstraints
                , bindValueConstraints
                , inValueConstraints
                , destructureConstraints
                ]

        Value.IfThenElse ( _, thisTypeVar ) condition thenBranch elseBranch ->
            let
                specificConstraints : ConstraintSet
                specificConstraints =
                    ConstraintSet.fromList
                        -- the condition should always be bool
                        [ equality (metaTypeVarForValue condition) MetaType.boolType

                        -- the two branches should have the same type
                        , equality (metaTypeVarForValue elseBranch) (metaTypeVarForValue thenBranch)

                        -- the final type should be the same as the branches (can use any branch thanks to previous rule)
                        , equality (MetaVar thisTypeVar) (metaTypeVarForValue thenBranch)
                        ]

                childConstraints : List ConstraintSet
                childConstraints =
                    [ constrainValue vars condition
                    , constrainValue vars thenBranch
                    , constrainValue vars elseBranch
                    ]
            in
            ConstraintSet.concat (specificConstraints :: childConstraints)

        Value.PatternMatch ( _, thisTypeVar ) subjectValue cases ->
            let
                thisType : MetaType
                thisType =
                    MetaVar thisTypeVar

                subjectType : MetaType
                subjectType =
                    metaTypeVarForValue subjectValue

                casesConstraints : List ConstraintSet
                casesConstraints =
                    cases
                        |> List.map
                            (\( casePattern, caseValue ) ->
                                let
                                    ( casePatternVariables, casePatternConstraints ) =
                                        constrainPattern casePattern

                                    caseValueConstraints : ConstraintSet
                                    caseValueConstraints =
                                        constrainValue (Dict.union casePatternVariables vars) caseValue

                                    caseConstraints : ConstraintSet
                                    caseConstraints =
                                        ConstraintSet.fromList
                                            [ equality subjectType (metaTypeVarForPattern casePattern)
                                            , equality thisType (metaTypeVarForValue caseValue)
                                            ]
                                in
                                ConstraintSet.concat
                                    [ casePatternConstraints
                                    , caseValueConstraints
                                    , caseConstraints
                                    ]
                            )
            in
            ConstraintSet.concat casesConstraints

        Value.UpdateRecord ( _, thisTypeVar ) subjectValue fieldValues ->
            let
                extendsVar : Variable
                extendsVar =
                    thisTypeVar
                        |> MetaType.subVariable

                extensibleRecordType : MetaType
                extensibleRecordType =
                    MetaRecord (Just extendsVar)
                        (fieldValues
                            |> List.map
                                (\( fieldName, fieldValue ) ->
                                    ( fieldName, metaTypeVarForValue fieldValue )
                                )
                            |> Dict.fromList
                        )

                fieldValueConstraints : ConstraintSet
                fieldValueConstraints =
                    fieldValues
                        |> List.map
                            (\( _, fieldValue ) ->
                                constrainValue vars fieldValue
                            )
                        |> ConstraintSet.concat

                fieldConstraints : ConstraintSet
                fieldConstraints =
                    ConstraintSet.fromList
                        [ equality (metaTypeVarForValue subjectValue) extensibleRecordType
                        , equality (MetaVar thisTypeVar) (metaTypeVarForValue subjectValue)
                        ]
            in
            ConstraintSet.concat
                [ constrainValue vars subjectValue
                , fieldValueConstraints
                , fieldConstraints
                ]

        Value.Unit ( _, thisTypeVar ) ->
            ConstraintSet.singleton
                (equality (MetaVar thisTypeVar) MetaUnit)


constrainPattern : Pattern ( va, Variable ) -> ( Dict Name Variable, ConstraintSet )
constrainPattern untypedPattern =
    case untypedPattern of
        Value.WildcardPattern _ ->
            ( Dict.empty, ConstraintSet.empty )

        Value.AsPattern ( _, thisTypeVar ) nestedPattern alias ->
            let
                ( nestedVariables, nestedConstraints ) =
                    constrainPattern nestedPattern

                thisPatternConstraints : ConstraintSet
                thisPatternConstraints =
                    ConstraintSet.singleton
                        (equality (MetaVar thisTypeVar) (metaTypeVarForPattern nestedPattern))
            in
            ( nestedVariables |> Dict.insert alias thisTypeVar
            , ConstraintSet.union nestedConstraints thisPatternConstraints
            )

        Value.TuplePattern ( _, thisTypeVar ) elemPatterns ->
            let
                ( elemsVariables, elemsConstraints ) =
                    elemPatterns
                        |> List.map constrainPattern
                        |> List.unzip

                tupleConstraint : ConstraintSet
                tupleConstraint =
                    ConstraintSet.singleton
                        (equality
                            (MetaVar thisTypeVar)
                            (elemPatterns
                                |> List.map metaTypeVarForPattern
                                |> MetaTuple
                            )
                        )
            in
            ( List.foldl Dict.union Dict.empty elemsVariables
            , ConstraintSet.concat (tupleConstraint :: elemsConstraints)
            )

        Value.ConstructorPattern ( _, thisTypeVar ) fQName argPatterns ->
            let
                ctorConstraints : ConstraintSet
                ctorConstraints =
                    ConstraintSet.singleton
                        (Constraint.lookupConstructor (MetaVar thisTypeVar) fQName)

                ( argVariables, argConstraints ) =
                    argPatterns
                        |> List.map constrainPattern
                        |> List.unzip
            in
            ( List.foldl Dict.union Dict.empty argVariables
            , ConstraintSet.concat (ctorConstraints :: argConstraints)
            )

        Value.EmptyListPattern ( _, thisTypeVar ) ->
            let
                itemType : MetaType
                itemType =
                    MetaVar (thisTypeVar |> MetaType.subVariable)

                listType : MetaType
                listType =
                    MetaType.listType itemType
            in
            ( Dict.empty
            , ConstraintSet.singleton
                (equality (MetaVar thisTypeVar) listType)
            )

        Value.HeadTailPattern ( _, thisTypeVar ) headPattern tailPattern ->
            let
                ( headVariables, headConstraints ) =
                    constrainPattern headPattern

                ( tailVariables, tailConstraints ) =
                    constrainPattern tailPattern

                itemType : MetaType
                itemType =
                    metaTypeVarForPattern headPattern

                listType : MetaType
                listType =
                    MetaType.listType itemType

                thisPatternConstraints : ConstraintSet
                thisPatternConstraints =
                    ConstraintSet.fromList
                        [ equality (MetaVar thisTypeVar) listType
                        , equality (metaTypeVarForPattern tailPattern) listType
                        ]
            in
            ( Dict.union headVariables tailVariables
            , ConstraintSet.concat
                [ headConstraints, tailConstraints, thisPatternConstraints ]
            )

        Value.LiteralPattern ( _, thisTypeVar ) literalValue ->
            ( Dict.empty, constrainLiteral thisTypeVar literalValue )

        Value.UnitPattern ( _, thisTypeVar ) ->
            ( Dict.empty
            , ConstraintSet.singleton
                (equality (MetaVar thisTypeVar) MetaUnit)
            )


constrainLiteral : Variable -> Literal -> ConstraintSet
constrainLiteral thisTypeVar literalValue =
    let
        expectExactType : MetaType -> ConstraintSet
        expectExactType expectedType =
            ConstraintSet.singleton
                (equality
                    (MetaVar thisTypeVar)
                    expectedType
                )
    in
    case literalValue of
        BoolLiteral _ ->
            expectExactType MetaType.boolType

        CharLiteral _ ->
            expectExactType MetaType.charType

        StringLiteral _ ->
            expectExactType MetaType.stringType

        IntLiteral _ ->
            ConstraintSet.singleton
                (class (MetaVar thisTypeVar) Class.Number)

        FloatLiteral _ ->
            expectExactType MetaType.floatType


solve : Variable -> References -> ConstraintSet -> Result TypeError ( ConstraintSet, SolutionMap )
solve baseVar refs constraintSet =
    solveHelp baseVar refs SolutionMap.empty constraintSet


solveHelp : Variable -> References -> SolutionMap -> ConstraintSet -> Result TypeError ( ConstraintSet, SolutionMap )
solveHelp baseVar refs solutionsSoFar ((ConstraintSet constraints) as constraintSet) =
    constraints
        |> validateConstraints
        |> Result.map removeTrivialConstraints
        |> Result.andThen
            (\nonTrivialConstraints ->
                nonTrivialConstraints
                    |> findSubstitution baseVar refs
                    |> Result.andThen
                        (\maybeNewSolutions ->
                            case maybeNewSolutions of
                                Nothing ->
                                    Ok ( ConstraintSet.fromList nonTrivialConstraints, solutionsSoFar )

                                Just newSolutions ->
                                    solutionsSoFar
                                        |> mergeSolutions baseVar refs newSolutions
                                        |> Result.andThen
                                            (\mergedSolutions ->
                                                solveHelp baseVar refs mergedSolutions (constraintSet |> ConstraintSet.applySubstitutions mergedSolutions)
                                            )
                        )
            )


removeTrivialConstraints : List Constraint -> List Constraint
removeTrivialConstraints constraints =
    constraints
        |> List.filter
            (\constraint ->
                case constraint of
                    Equality metaType1 metaType2 ->
                        metaType1 /= metaType2

                    Class metaType _ ->
                        case metaType of
                            -- If this is a variable we still need to resolve it
                            MetaVar _ ->
                                True

                            -- Otherwise it's a specific type already so we can remove this constraint
                            _ ->
                                False

                    LookupConstructor metaType _ ->
                        case metaType of
                            -- If this is a variable we still need to resolve it
                            MetaVar _ ->
                                True

                            -- Otherwise it's a specific type already so we can remove this constraint
                            _ ->
                                False

                    LookupValue metaType _ ->
                        case metaType of
                            -- If this is a variable we still need to resolve it
                            MetaVar _ ->
                                True

                            -- Otherwise it's a specific type already so we can remove this constraint
                            _ ->
                                False
            )


validateConstraints : List Constraint -> Result TypeError (List Constraint)
validateConstraints constraints =
    constraints
        |> List.map
            (\constraint ->
                case constraint of
                    Class (MetaVar _) _ ->
                        Ok constraint

                    Class metaType class ->
                        if Class.member metaType class then
                            Ok constraint

                        else
                            Err (ClassConstraintViolation metaType class)

                    _ ->
                        Ok constraint
            )
        |> ListOfResults.liftAllErrors
        |> Result.mapError typeErrors


findSubstitution : Variable -> References -> List Constraint -> Result TypeError (Maybe SolutionMap)
findSubstitution baseVar refs constraints =
    case constraints of
        [] ->
            Ok Nothing

        firstConstraint :: restOfConstraints ->
            case firstConstraint of
                Equality metaType1 metaType2 ->
                    unifyMetaType baseVar refs metaType1 metaType2
                        |> Result.andThen
                            (\solutions ->
                                if SolutionMap.isEmpty solutions then
                                    findSubstitution baseVar refs restOfConstraints

                                else
                                    Ok (Just solutions)
                            )

                Class _ _ ->
                    findSubstitution baseVar refs restOfConstraints

                LookupConstructor metaType1 fQName ->
                    lookupConstructor baseVar refs fQName
                        |> Result.mapError LookupError
                        |> Result.andThen
                            (\metaType2 ->
                                unifyMetaType baseVar refs metaType1 metaType2
                                    |> Result.andThen
                                        (\solutions ->
                                            if SolutionMap.isEmpty solutions then
                                                findSubstitution baseVar refs restOfConstraints

                                            else
                                                Ok (Just solutions)
                                        )
                            )

                LookupValue metaType1 fQName ->
                    lookupValue baseVar refs fQName
                        |> Result.mapError LookupError
                        |> Result.andThen
                            (\metaType2 ->
                                unifyMetaType baseVar refs metaType1 metaType2
                                    |> Result.andThen
                                        (\solutions ->
                                            if SolutionMap.isEmpty solutions then
                                                findSubstitution baseVar refs restOfConstraints

                                            else
                                                Ok (Just solutions)
                                        )
                            )


addSolution : Variable -> References -> Variable -> MetaType -> SolutionMap -> Result TypeError SolutionMap
addSolution baseVar refs var newSolution (SolutionMap currentSolutions) =
    case Dict.get var currentSolutions of
        Just existingSolution ->
            -- Unify with the existing solution
            unifyMetaType baseVar refs existingSolution newSolution
                |> Result.map
                    (\(SolutionMap newSubstitutions) ->
                        -- If it unifies apply the substitutions to the existing solution and add all new substitutions
                        SolutionMap
                            (currentSolutions
                                |> Dict.insert var
                                    (existingSolution
                                        |> MetaType.substituteVariables (Dict.toList newSubstitutions)
                                    )
                                |> Dict.union newSubstitutions
                            )
                    )

        Nothing ->
            -- Simply substitute and insert the new solution
            currentSolutions
                |> Dict.insert var newSolution
                |> SolutionMap
                |> SolutionMap.substituteVariable var newSolution
                |> Ok


mergeSolutions : Variable -> References -> SolutionMap -> SolutionMap -> Result TypeError SolutionMap
mergeSolutions baseVar refs (SolutionMap newSolutions) currentSolutions =
    newSolutions
        |> Dict.toList
        |> List.foldl
            (\( var, newSolution ) solutionsSoFar ->
                solutionsSoFar
                    |> Result.andThen (addSolution baseVar refs var newSolution)
            )
            (Ok currentSolutions)


concatSolutions : Variable -> References -> List SolutionMap -> Result TypeError SolutionMap
concatSolutions baseVar refs solutionMaps =
    solutionMaps
        |> List.foldl
            (\nextSolutions resultSoFar ->
                resultSoFar
                    |> Result.andThen
                        (\solutionsSoFar ->
                            mergeSolutions baseVar refs solutionsSoFar nextSolutions
                        )
            )
            (Ok SolutionMap.empty)


unifyMetaType : Variable -> References -> MetaType -> MetaType -> Result TypeError SolutionMap
unifyMetaType baseVar refs metaType1 metaType2 =
    if metaType1 == metaType2 then
        Ok SolutionMap.empty

    else
        case metaType1 of
            MetaVar var1 ->
                unifyVariable var1 metaType2

            MetaTuple elems1 ->
                unifyTuple baseVar refs elems1 metaType2

            MetaRef ref1 ->
                unifyRef baseVar refs ref1 metaType2

            MetaApply fun1 arg1 ->
                unifyApply baseVar refs fun1 arg1 metaType2

            MetaFun arg1 return1 ->
                unifyFun baseVar refs arg1 return1 metaType2

            MetaRecord extends1 fields1 ->
                unifyRecord baseVar refs extends1 fields1 metaType2

            MetaUnit ->
                unifyUnit metaType2


unifyVariable : Variable -> MetaType -> Result TypeError SolutionMap
unifyVariable var1 metaType2 =
    Ok (SolutionMap.singleton var1 metaType2)


unifyTuple : Variable -> References -> List MetaType -> MetaType -> Result TypeError SolutionMap
unifyTuple baseVar refs elems1 metaType2 =
    case metaType2 of
        MetaVar var2 ->
            unifyVariable var2 (MetaTuple elems1)

        MetaTuple elems2 ->
            if List.length elems1 == List.length elems2 then
                List.map2 (unifyMetaType baseVar refs) elems1 elems2
                    |> ListOfResults.liftAllErrors
                    |> Result.mapError TypeErrors
                    |> Result.andThen (concatSolutions baseVar refs)

            else
                Err (CouldNotUnify TuplesOfDifferentSize (MetaTuple elems1) metaType2)

        _ ->
            Err (CouldNotUnify NoUnificationRule (MetaTuple elems1) metaType2)


unifyRef : Variable -> References -> FQName -> MetaType -> Result TypeError SolutionMap
unifyRef baseVar refs ref1 metaType2 =
    case metaType2 of
        MetaVar var2 ->
            unifyVariable var2 (MetaRef ref1)

        MetaRef ref2 ->
            if ref1 == ref2 then
                Ok SolutionMap.empty

            else
                Err (CouldNotUnify RefMismatch (MetaRef ref1) metaType2)

        MetaRecord extends2 fields2 ->
            unifyRecord baseVar refs extends2 fields2 (MetaRef ref1)

        other ->
            Err (CouldNotUnify NoUnificationRule (MetaRef ref1) metaType2)


unifyApply : Variable -> References -> MetaType -> MetaType -> MetaType -> Result TypeError SolutionMap
unifyApply baseVar refs fun1 arg1 metaType2 =
    case metaType2 of
        MetaVar var2 ->
            unifyVariable var2 (MetaApply fun1 arg1)

        MetaApply fun2 arg2 ->
            Result.andThen identity
                (Result.map2 (mergeSolutions baseVar refs)
                    (unifyMetaType baseVar refs fun1 fun2)
                    (unifyMetaType baseVar refs arg1 arg2)
                )

        _ ->
            Err (CouldNotUnify NoUnificationRule (MetaApply fun1 arg1) metaType2)


unifyFun : Variable -> References -> MetaType -> MetaType -> MetaType -> Result TypeError SolutionMap
unifyFun baseVar refs arg1 return1 metaType2 =
    case metaType2 of
        MetaVar var2 ->
            unifyVariable var2 (MetaFun arg1 return1)

        MetaFun arg2 return2 ->
            Result.andThen identity
                (Result.map2 (mergeSolutions baseVar refs)
                    (unifyMetaType baseVar refs arg1 arg2)
                    (unifyMetaType baseVar refs return1 return2)
                )

        _ ->
            Err (CouldNotUnify NoUnificationRule (MetaFun arg1 return1) metaType2)


unifyRecord : Variable -> References -> Maybe Variable -> Dict Name MetaType -> MetaType -> Result TypeError SolutionMap
unifyRecord baseVar refs extends1 fields1 metaType2 =
    case metaType2 of
        MetaVar var2 ->
            unifyVariable var2 (MetaRecord extends1 fields1)

        MetaRef ref2 ->
            lookupAliasedType baseVar refs ref2
                |> Result.mapError LookupError
                |> Result.andThen (unifyRecord baseVar refs extends1 fields1)

        MetaRecord extends2 fields2 ->
            unifyFields baseVar refs extends1 fields1 extends2 fields2
                |> Result.andThen
                    (\( newFields, fieldSolutions ) ->
                        case extends1 of
                            Just extendsVar1 ->
                                mergeSolutions baseVar
                                    refs
                                    fieldSolutions
                                    (SolutionMap.singleton extendsVar1
                                        (MetaRecord extends2 newFields)
                                    )

                            Nothing ->
                                case extends2 of
                                    Just extendsVar2 ->
                                        mergeSolutions baseVar
                                            refs
                                            fieldSolutions
                                            (SolutionMap.singleton extendsVar2
                                                (MetaRecord extends1 newFields)
                                            )

                                    Nothing ->
                                        Ok fieldSolutions
                    )

        _ ->
            Err (CouldNotUnify NoUnificationRule (MetaRecord extends1 fields1) metaType2)


unifyFields : Variable -> References -> Maybe Variable -> Dict Name MetaType -> Maybe Variable -> Dict Name MetaType -> Result TypeError ( Dict Name MetaType, SolutionMap )
unifyFields baseVar refs oldExtends oldFields newExtends newFields =
    let
        extraOldFields : Dict Name MetaType
        extraOldFields =
            Dict.diff oldFields newFields

        extraNewFields : Dict Name MetaType
        extraNewFields =
            Dict.diff newFields oldFields

        commonFieldsOldType : Dict Name MetaType
        commonFieldsOldType =
            Dict.intersect oldFields newFields

        fieldSolutionsResult : Result TypeError SolutionMap
        fieldSolutionsResult =
            commonFieldsOldType
                |> Dict.toList
                |> List.map
                    (\( fieldName, originalType ) ->
                        newFields
                            |> Dict.get fieldName
                            -- this should never happen but needed for type-safety
                            |> Result.fromMaybe (UnknownError ("Could not find field " ++ Name.toCamelCase fieldName))
                            |> Result.andThen (unifyMetaType baseVar refs originalType)
                    )
                |> ListOfResults.liftAllErrors
                |> Result.mapError typeErrors
                |> Result.andThen (concatSolutions baseVar refs)

        unifiedFields : Dict Name MetaType
        unifiedFields =
            Dict.union commonFieldsOldType
                (Dict.union extraOldFields extraNewFields)
    in
    if oldExtends == Nothing && not (Dict.isEmpty extraNewFields) then
        Err (CouldNotUnify FieldMismatch (MetaRecord oldExtends oldFields) (MetaRecord newExtends newFields))

    else if newExtends == Nothing && not (Dict.isEmpty extraOldFields) then
        Err (CouldNotUnify FieldMismatch (MetaRecord oldExtends oldFields) (MetaRecord newExtends newFields))

    else
        fieldSolutionsResult
            |> Result.map (Tuple.pair unifiedFields)


unifyUnit : MetaType -> Result TypeError SolutionMap
unifyUnit metaType2 =
    case metaType2 of
        MetaVar var2 ->
            unifyVariable var2 MetaUnit

        _ ->
            Err (CouldNotUnify NoUnificationRule MetaUnit metaType2)


applySolutionToAnnotatedDefinition : Value.Definition ta ( va, Variable ) -> ( ConstraintSet, SolutionMap ) -> Value.Definition ta ( va, Type () )
applySolutionToAnnotatedDefinition annotatedDef ( residualConstraints, solutionMap ) =
    annotatedDef
        |> Value.mapDefinitionAttributes identity
            (\( va, metaVar ) ->
                ( va
                , solutionMap
                    |> SolutionMap.get metaVar
                    |> Maybe.map (metaTypeToConcreteType solutionMap)
                    |> Maybe.withDefault (metaVar |> MetaType.toName |> Type.Variable ())
                )
            )


applySolutionToAnnotatedValue : Value () ( va, Variable ) -> ( ConstraintSet, SolutionMap ) -> TypedValue va
applySolutionToAnnotatedValue annotatedValue ( residualConstraints, solutionMap ) =
    annotatedValue
        |> Value.mapValueAttributes identity
            (\( va, metaVar ) ->
                ( va
                , solutionMap
                    |> SolutionMap.get metaVar
                    |> Maybe.map (metaTypeToConcreteType solutionMap)
                    |> Maybe.withDefault (metaVar |> MetaType.toName |> Type.Variable ())
                )
            )


typeErrors : List TypeError -> TypeError
typeErrors errors =
    case errors of
        [ single ] ->
            single

        _ ->
            TypeErrors errors


metaTypeVarForValue : Value ta ( va, Variable ) -> MetaType
metaTypeVarForValue value =
    value
        |> Value.valueAttribute
        |> Tuple.second
        |> MetaVar


metaTypeVarForPattern : Pattern ( va, Variable ) -> MetaType
metaTypeVarForPattern pattern =
    pattern
        |> Value.patternAttribute
        |> Tuple.second
        |> MetaVar
