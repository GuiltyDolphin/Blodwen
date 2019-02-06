module Core.CaseBuilder

import public Core.CaseTree
import Core.Context
import Core.Normalise
import Core.TT

import Control.Monad.State
import Data.List

%default covering

public export
data Phase = CompileTime | RunTime

data ArgType : List Name -> Type where
     Known : RigCount -> (ty : Term vars) -> ArgType vars -- arg has type 'ty'
     Stuck : (fty : Term vars) -> ArgType vars 
         -- ^ arg will have argument type of 'fty' when we know enough to
         -- calculate it
     Unknown : ArgType vars
         -- arg's type is not yet known due to a previously stuck argument

Show (ArgType ns) where
  show (Known c t) = "Known " ++ show c ++ " " ++ show t
  show (Stuck t) = "Stuck " ++ show t
  show Unknown = "Unknown"

record PatInfo (pvar : Name) (vars : List Name) where
  constructor MkInfo
  pat : Pat
  loc : Elem pvar vars
  argType : ArgType vars -- Type of the argument being inspected (i.e. 
                         -- *not* refined by this particular pattern)

{-
NamedPats is a list of patterns on the LHS of a clause. Each entry in
the list gives a pattern, and a proof that there is a variable we can
inspect to see if it matches the pattern.

A definition consists of a list of clauses, which are a 'NamedPats' and
a term on the RHS. There is an assumption that corresponding positions in
NamedPats always have the same 'Elem' proof, though this isn't expressed in
a type anywhere.
-}

data NamedPats : List Name -> -- pattern variables still to process
                 List Name -> -- the pattern variables still to process,
                              -- in order
                 Type where
     Nil : NamedPats vars []
     (::) : PatInfo pvar vars -> 
            -- ^ a pattern, where its variable appears in the vars list,
            -- and its type. The type has no variable names; any names it
            -- refers to are explicit
            NamedPats vars ns -> NamedPats vars (pvar :: ns)

getPatInfo : NamedPats vars todo -> List Pat
getPatInfo [] = []
getPatInfo (x :: xs) = pat x :: getPatInfo xs

updatePats : Env Term vars -> 
             NF vars -> NamedPats vars todo -> NamedPats vars todo
updatePats env nf [] = []
updatePats {todo = pvar :: ns} env (NBind _ (Pi c _ farg) fsc) (p :: ps)
  = case argType p of
         Unknown =>
            record { argType = Known c (quote initCtxt env farg) } p
              :: updatePats env (fsc (toClosure defaultOpts env (Ref Bound pvar))) ps
         _ => p :: ps
updatePats env nf (p :: ps)
  = case argType p of
         Unknown => record { argType = Stuck (quote initCtxt env nf) } p :: ps
         _ => p :: ps

mkEnv : (vs : List Name) -> Env Term vs
mkEnv [] = []
mkEnv (n :: ns) = PVar RigW Erased :: mkEnv ns

substInPatInfo : Defs -> Name -> Term vars -> PatInfo pvar vars -> 
                 NamedPats vars todo -> (PatInfo pvar vars, NamedPats vars todo)
substInPatInfo {pvar} {vars} defs n tm p ps 
    = case argType p of
           Known c ty => (record { argType = Known c (substName n tm ty) } p, ps)
           Stuck fty => let env = mkEnv vars in
                          case nf defs env (substName n tm fty) of
                             NBind _ (Pi c _ farg) fsc =>
                               (record { argType = Known c (quote initCtxt env farg) } p,
                                   updatePats env 
                                      (fsc (toClosure defaultOpts env
                                                (Ref Bound pvar))) ps)
                             _ => (p, ps)
           Unknown => (p, ps)

-- Substitute the name with a term in the pattern types, and reduce further
-- (this aims to resolve any 'Stuck' pattern types)
substInPats : Defs -> Name -> Term vars -> NamedPats vars todo -> NamedPats vars todo
substInPats defs n tm [] = []
substInPats defs n tm (p :: ps) 
    = let (p', ps') = substInPatInfo defs n tm p ps in
          p' :: substInPats defs n tm ps'

getPat : Elem x ps -> NamedPats ns ps -> PatInfo x ns
getPat Here (x :: xs) = x
getPat (There later) (x :: xs) = getPat later xs

dropPat : (el : Elem x ps) -> NamedPats ns ps -> NamedPats ns (dropElem ps el)
dropPat Here (x :: xs) = xs
dropPat (There later) (x :: xs) = x :: dropPat later xs

Show (NamedPats vars todo) where
  show xs = "[" ++ showAll xs ++ "]"
    where
      showAll : NamedPats vs ts -> String
      showAll [] = ""
      showAll {ts = t :: _ } [x]
          = show t ++ " " ++ show (pat x) ++ " [" ++ show (argType x) ++ "]" 
      showAll {ts = t :: _ } (x :: xs) 
          = show t ++ " " ++ show (pat x) ++ " [" ++ show (argType x) ++ "]"
                     ++ ", " ++ showAll xs

Weaken ArgType where
  weaken (Known c ty) = Known c (weaken ty)
  weaken (Stuck fty) = Stuck (weaken fty)
  weaken Unknown = Unknown

Weaken (PatInfo p) where
  weaken (MkInfo p el fty) = MkInfo p (There el) (weaken fty)

-- FIXME: oops, 'vars' should be second argument so we can use Weaken interface
weaken : NamedPats vars todo -> NamedPats (x :: vars) todo
weaken [] = []
weaken (p :: ps) = weaken p :: weaken ps

weakenNs : (ns : List Name) -> 
           NamedPats vars todo -> NamedPats (ns ++ vars) todo
weakenNs ns [] = []
weakenNs ns (p :: ps) 
    = weakenNs ns p :: weakenNs ns ps

(++) : NamedPats vars ms -> NamedPats vars ns -> NamedPats vars (ms ++ ns)
(++) [] ys = ys
(++) (x :: xs) ys = x :: xs ++ ys

tail : NamedPats vars (p :: ps) -> NamedPats vars ps
tail (x :: xs) = xs

take : (as : List Name) -> NamedPats vars (as ++ bs) -> NamedPats vars as
take [] ps = []
take (x :: xs) (p :: ps) = p :: take xs ps

data PatClause : (vars : List Name) -> (todo : List Name) -> Type where
     MkPatClause : List Name -> -- names matched so far (from original lhs)
                   NamedPats vars todo -> 
                   (rhs : Term vars) -> PatClause vars todo

getNPs : PatClause vars todo -> NamedPats vars todo
getNPs (MkPatClause _ lhs rhs) = lhs

Show (PatClause vars todo) where
  show (MkPatClause _ ps rhs) 
     = show (getPatInfo ps) ++ " => " ++ show rhs

substInClause : Defs -> PatClause vars (a :: todo) -> PatClause vars (a :: todo)
substInClause {vars} {a} defs (MkPatClause pvars (MkInfo pat pprf fty :: pats) rhs)
    = MkPatClause pvars (MkInfo pat pprf fty :: 
                           substInPats defs a (mkTerm vars pat) pats) rhs

data LengthMatch : List a -> List b -> Type where
     NilMatch : LengthMatch [] []
     ConsMatch : LengthMatch xs ys -> LengthMatch (x :: xs) (y :: ys)

checkLengthMatch : (xs : List a) -> (ys : List b) -> Maybe (LengthMatch xs ys)
checkLengthMatch [] [] = Just NilMatch
checkLengthMatch [] (x :: xs) = Nothing
checkLengthMatch (x :: xs) [] = Nothing
checkLengthMatch (x :: xs) (y :: ys) 
    = Just (ConsMatch !(checkLengthMatch xs ys))

data Partitions : List (PatClause vars todo) -> Type where
     ConClauses : (cs : List (PatClause vars todo)) ->
                  Partitions ps -> Partitions (cs ++ ps)
     VarClauses : (vs : List (PatClause vars todo)) ->
                  Partitions ps -> Partitions (vs ++ ps)
     NoClauses : Partitions []

Show (Partitions ps) where
  show (ConClauses cs rest) = "CON " ++ show cs ++ ", " ++ show rest
  show (VarClauses vs rest) = "VAR " ++ show vs ++ ", " ++ show rest
  show NoClauses = "NONE"

data ClauseType = ConClause | VarClause

namesIn : List Name -> Pat -> Bool
namesIn pvars (PCon _ _ ps) = all (namesIn pvars) ps
namesIn pvars (PTCon _ _ ps) = all (namesIn pvars) ps
namesIn pvars (PVar n) = n `elem` pvars
namesIn pvars _ = True

namesFrom : Pat -> List Name
namesFrom (PCon _ _ ps) = concatMap namesFrom ps
namesFrom (PTCon _ _ ps) = concatMap namesFrom ps
namesFrom (PVar n) = [n]
namesFrom _ = []

clauseType : Phase -> PatClause vars (a :: as) -> ClauseType
-- If it's irrelevant, a constructor, and there's no names we haven't seen yet
-- and don't see later, treat it as a variable
-- Or, if we're compiling for runtime we won't be able to split on it, so
-- also treat it as a variable
clauseType CompileTime (MkPatClause pvars (MkInfo (PCon x y xs) _ (Known Rig0 t) :: rest) rhs) 
    = if all (namesIn (pvars ++ concatMap namesFrom (getPatInfo rest))) xs
         then VarClause
         else ConClause
clauseType phase (MkPatClause pvars (MkInfo _ _ (Known Rig0 t) :: _) rhs) 
    = VarClause
clauseType phase (MkPatClause _ (MkInfo (PCon x y xs) _ _ :: _) rhs) = ConClause
clauseType phase (MkPatClause _ (MkInfo (PTCon x y xs) _ _ :: _) rhs) = ConClause
clauseType phase (MkPatClause _ (MkInfo (PConst x) _ _ :: _) rhs) = ConClause
clauseType phase (MkPatClause _ (_ :: _) rhs) = VarClause

partition : Phase -> (ps : List (PatClause vars (a :: as))) -> Partitions ps
partition phase [] = NoClauses
partition phase (x :: xs) with (partition phase xs)
  partition phase (x :: (cs ++ ps)) | (ConClauses cs rest) 
        = case clauseType phase x of
               ConClause => ConClauses (x :: cs) rest
               VarClause => VarClauses [x] (ConClauses cs rest)
  partition phase (x :: (vs ++ ps)) | (VarClauses vs rest) 
        = case clauseType phase x of
               ConClause => ConClauses [x] (VarClauses vs rest)
               VarClause => VarClauses (x :: vs) rest
  partition phase (x :: []) | NoClauses
        = case clauseType phase x of
               ConClause => ConClauses [x] NoClauses
               VarClause => VarClauses [x] NoClauses

data ConType : Type where
     CName : Name -> (tag : Int) -> ConType
     CConst : Constant -> ConType

conTypeEq : (x, y : ConType) -> Maybe (x = y)
conTypeEq (CName x tag) (CName x' tag') 
   = do Refl <- nameEq x x'
        case decEq tag tag' of
             Yes Refl => Just Refl
             No contra => Nothing
conTypeEq (CName x tag) (CConst y) = Nothing
conTypeEq (CConst x) (CName y tag) = Nothing
conTypeEq (CConst x) (CConst y) 
   = case constantEq x y of
          Nothing => Nothing
          Just Refl => Just Refl

data Group : List Name -> -- variables in scope
             List Name -> -- pattern variables still to process
             Type where
     ConGroup : Name -> (tag : Int) -> 
                List (PatClause (newargs ++ vars) (newargs ++ todo)) ->
                Group vars todo
     ConstGroup : Constant -> List (PatClause vars todo) ->
                  Group vars todo

Show (Group vars todo) where
  show (ConGroup c t cs) = "Con " ++ show c ++ ": " ++ show cs
  show (ConstGroup c cs) = "Const " ++ show c ++ ": " ++ show cs

data GroupMatch : ConType -> List Pat -> Group vars todo -> Type where
  ConMatch : LengthMatch ps newargs ->
             GroupMatch (CName n tag) ps 
               (ConGroup {newargs} n tag (MkPatClause pvs pats rhs :: rest))
  ConstMatch : GroupMatch (CConst c) []
                  (ConstGroup c (MkPatClause pvs pats rhs :: rest))
  NoMatch : GroupMatch ct ps g

checkGroupMatch : (c : ConType) -> (ps : List Pat) -> (g : Group vars todo) ->
                  GroupMatch c ps g
checkGroupMatch (CName x tag) ps (ConGroup {newargs} x' tag' (MkPatClause pvs pats rhs :: rest)) 
    = case checkLengthMatch ps newargs of
           Nothing => NoMatch
           Just prf => case (nameEq x x', decEq tag tag') of
                            (Just Refl, Yes Refl) => ConMatch prf
                            _ => NoMatch
checkGroupMatch (CName x tag) ps (ConstGroup _ xs) = NoMatch
checkGroupMatch (CConst x) ps (ConGroup _ _ xs) = NoMatch
checkGroupMatch (CConst c) [] (ConstGroup c' (MkPatClause pvs pats rhs :: rest)) 
    = case constantEq c c' of
           Nothing => NoMatch
           Just Refl => ConstMatch
checkGroupMatch _ _ _ = NoMatch

nextName : String -> StateT Int (Either CaseError) Name
nextName root
    = do i <- get
         put (i + 1)
         pure (MN root i)

nextNames : String -> List Pat -> Maybe (NF vars) ->
            StateT Int (Either CaseError) (args ** NamedPats (args ++ vars) args)
nextNames root [] fty = pure ([] ** [])
nextNames {vars} root (p :: pats) fty
     = do n <- nextName root
          let env = mkEnv vars
          let fa_tys : (Maybe (NF vars), ArgType vars)
                  = case fty of
                         Nothing => (Nothing, Unknown)
                         Just (NBind _ (Pi c _ NErased) fsc) =>
                            (Just (fsc (toClosure defaultOpts env (Ref Bound n))),
                              Unknown)
                         Just (NBind _ (Pi c _ farg) fsc) =>
                            (Just (fsc (toClosure defaultOpts env (Ref Bound n))),
                              Known c (quote initCtxt env farg))
                         Just t =>
                            (Nothing, Stuck (quote initCtxt env t))
          (args ** ps) <- nextNames {vars} root pats
                               (fst fa_tys)
          let argTy = case snd fa_tys of
                           Unknown => Unknown
                           Known rig t => Known rig (weakenNs (n :: args) t)
                           Stuck t => Stuck (weakenNs (n :: args) t)
          pure (n :: args ** MkInfo p Here argTy :: weaken ps)

-- replace the prefix of patterns with 'pargs'
newPats : (pargs : List Pat) -> LengthMatch pargs ns ->
          NamedPats vars (ns ++ todo) ->
          NamedPats vars ns 
newPats [] NilMatch rest = []
newPats (newpat :: xs) (ConsMatch w) (pi :: rest) 
  = record { pat = newpat} pi :: newPats xs w rest

substPatNames : (ns : _) -> NamedPats vars ns -> Term vars -> Term vars
substPatNames [] [] tm = tm
substPatNames (n :: ns) (MkInfo (PVar pn) _ _ :: ps) tm 
     = substName pn (Ref Bound n) (substPatNames ns ps tm)
substPatNames (n :: ns) (_ :: ps) tm = substPatNames ns ps tm

updateNames : List (Name, Pat) -> List (Name, Name)
updateNames = mapMaybe update
  where
    update : (Name, Pat) -> Maybe (Name, Name)
    update (n, PVar p) = Just (p, n)
    update _ = Nothing

updatePatNames : List (Name, Name) -> NamedPats vars todo -> NamedPats vars todo
updatePatNames _ [] = []
updatePatNames ns (pi :: ps)
    = record { pat $= update } pi :: updatePatNames ns ps
  where
    update : Pat -> Pat
    update (PCon n i ps) = PCon n i (map update ps)
    update (PTCon n i ps) = PTCon n i (map update ps)
    update (PVar n) = case lookup n ns of
                           Nothing => PVar n
                           Just n' => PVar n'
    update p = p

groupCons : Defs ->
            List Name ->
            List (PatClause vars (a :: todo)) -> 
            StateT Int (Either CaseError) (List (Group vars todo))
groupCons defs pvars cs 
     = gc [] cs
  where
    addConG : Name -> (tag : Int) -> List Pat -> NamedPats vars todo ->
              (rhs : Term vars) ->
              (acc : List (Group vars todo)) ->
              StateT Int (Either CaseError) (List (Group vars todo))
    -- Group all the clauses that begin with the same constructor, and
    -- add new pattern arguments for each of that constructor's arguments.
    -- The type of 'ConGroup' ensures that we refer to the arguments by
    -- the same name in each of the clauses
    addConG {todo} n tag pargs pats rhs [] 
        = do let cty 
                 = if n == UN "->"
                      then NBind (MN "_" 0) (Pi RigW Explicit NType) $
                              const $ NBind (MN "_" 1) (Pi RigW Explicit NErased) $
                                const NType
                      else case lookupTyExact n (gamma defs) of
                              Just t => nf defs (mkEnv vars) (embed t)
                              _ => NErased
             (patnames ** newargs) <- nextNames {vars} "e" pargs (Just cty)
             -- Update non-linear names in remaining patterns (to keep
             -- explicit dependencies in types accurate)
             let pats' = updatePatNames (updateNames (zip patnames pargs))
                                        (weakenNs patnames pats)
             let clause = MkPatClause {todo = patnames ++ todo} 
                              pvars 
                              (newargs ++ pats') 
                              (weakenNs patnames rhs)
             pure [ConGroup n tag [clause]]
    addConG {todo} n tag pargs pats rhs (g :: gs) with (checkGroupMatch (CName n tag) pargs g)
      addConG {todo} n tag pargs pats rhs
              ((ConGroup {newargs} n tag ((MkPatClause pvars ps tm) :: rest)) :: gs)
                   | (ConMatch {newargs} lprf) 
        = do let newps = newPats pargs lprf ps
             let pats' = updatePatNames (updateNames (zip newargs pargs))
                                        (weakenNs newargs pats)
             let newclause : PatClause (newargs ++ vars) (newargs ++ todo)
                   = MkPatClause pvars
                                 (newps ++ pats')
                                 (weakenNs newargs rhs)
             -- put the new clause at the end of the group, since we
             -- match the clauses top to bottom.
             pure ((ConGroup n tag (MkPatClause pvars ps tm :: rest ++ [newclause]))
                         :: gs)
      addConG n tag pargs pats rhs (g :: gs) | NoMatch 
        = do gs' <- addConG n tag pargs pats rhs gs
             pure (g :: gs')

    addConstG : Constant -> NamedPats vars todo ->
                (rhs : Term vars) ->
                (acc : List (Group vars todo)) ->
                StateT Int (Either CaseError) (List (Group vars todo))
    addConstG c pats rhs [] 
        = pure [ConstGroup c [MkPatClause pvars pats rhs]]
    addConstG {todo} c pats rhs (g :: gs) with (checkGroupMatch (CConst c) [] g)
      addConstG {todo} c pats rhs
              ((ConstGroup c ((MkPatClause pvars ps tm) :: rest)) :: gs) | ConstMatch                    
          = let newclause : PatClause vars todo
                  = MkPatClause pvars pats rhs in
                pure ((ConstGroup c 
                      (MkPatClause pvars ps tm :: rest ++ [newclause])) :: gs)
      addConstG c pats rhs (g :: gs) | NoMatch 
          = do gs' <- addConstG c pats rhs gs
               pure (g :: gs')
 
    addGroup : Pat -> NamedPats vars todo -> Term vars -> 
               List (Group vars todo) -> 
               StateT Int (Either CaseError) (List (Group vars todo))
    addGroup (PCon n t pargs) pats rhs acc 
         = addConG n t pargs pats rhs acc
    addGroup (PTCon n t pargs) pats rhs acc 
         = addConG n t pargs pats rhs acc
    addGroup (PConst c) pats rhs acc 
        = addConstG c pats rhs acc
    addGroup _ pats rhs acc = pure acc -- Can't happen, not a constructor
        -- FIXME: Is this possible to rule out with a type? Probably.

    gc : List (Group vars todo) -> 
         List (PatClause vars (a :: todo)) -> 
         StateT Int (Either CaseError) (List (Group vars todo))
    gc acc [] = pure acc
    gc {a} acc ((MkPatClause pvars (MkInfo pat pprf fty :: pats) rhs) :: cs) 
        = do acc' <- addGroup pat pats rhs acc
             gc acc' cs

getFirstPat : NamedPats ns (p :: ps) -> Pat
getFirstPat (p :: _) = pat p

getFirstArgType : NamedPats ns (p :: ps) -> ArgType ns
getFirstArgType (p :: _) = argType p

-- Check whether all the initial patterns have the same concrete, known
-- and matchable type, which is multiplicity > 0. 
-- If so, it's okay to match on it
sameType : Defs -> Env Term ns -> List (NamedPats ns (p :: ps)) -> 
           Either CaseError ()
sameType defs env [] = Right ()
sameType {ns} defs env (p :: xs) = -- all known (map getFirstArgType (p :: xs)) &&
    case getFirstArgType p of
         Known _ t => sameTypeAs (nf defs env t) (map getFirstArgType xs)
         _ => Left DifferingTypes
  where
    firstPat : NamedPats ns (np :: nps) -> Pat
    firstPat (pinf :: _) = pat pinf

    headEq : NF ns -> NF ns -> Bool
    headEq (NTCon n _ _ _) (NTCon n' _ _ _) = n == n'
    headEq (NPrimVal c) (NPrimVal c') = c == c'
    headEq NType NType = True
    headEq _ _ = False

    sameTypeAs : NF ns -> List (ArgType ns) -> Either CaseError ()
    sameTypeAs ty [] = Right ()
    sameTypeAs ty (Known Rig0 t :: xs) 
          = Left (MatchErased (_ ** (env, mkTerm _ (firstPat p))))  -- Can't match on erased thing
    sameTypeAs ty (Known c t :: xs) 
          = if headEq ty (nf defs env t)
               then sameTypeAs ty xs
               else Left DifferingTypes
    sameTypeAs ty _ = Left DifferingTypes

-- Check whether all the initial patterns are the same, or are all a variable.
-- If so, we'll match it to refine later types and move on
samePat : List (NamedPats ns (p :: ps)) -> Bool
samePat [] = True
samePat (pi :: xs) = samePatAs (getFirstPat pi) (map getFirstPat xs)
  where
    samePatAs : Pat -> List Pat -> Bool
    samePatAs p [] = True
    samePatAs (PTCon n t args) (PTCon n' t' _ :: ps)
        = if n == n' && t == t'
             then samePatAs (PTCon n t args) ps
             else False
    samePatAs (PCon n t args) (PCon n' t' _ :: ps)
        = if n == n' && t == t'
             then samePatAs (PCon n t args) ps
             else False
    samePatAs (PConstTy c) (PConstTy c' :: ps)
        = if c == c' 
             then samePatAs (PConstTy c) ps
             else False
    samePatAs (PConst c) (PConst c' :: ps)
        = if c == c' 
             then samePatAs (PConst c) ps
             else False
    samePatAs (PVar n) (PVar _ :: ps) = samePatAs (PVar n) ps
    samePatAs x y = False

getFirstCon : NamedPats ns (p :: ps) -> Pat
getFirstCon (p :: _) = pat p

-- Count the number of distinct constructors in the initial pattern
countDiff : List (NamedPats ns (p :: ps)) -> Nat
countDiff xs = length (distinct [] (map getFirstCon xs))
  where
    isVar : Pat -> Bool
    isVar (PCon _ _ _) = False
    isVar (PTCon _ _ _) = False
    isVar (PConst _) = False
    isVar _ = True

    -- Return whether two patterns would lead to the same match
    sameCase : Pat -> Pat -> Bool
    sameCase (PCon _ t _) (PCon _ t' _) = t == t'
    sameCase (PTCon _ t _) (PTCon _ t' _) = t == t'
    sameCase (PConst c) (PConst c') = c == c'
    sameCase x y = isVar x && isVar y

    distinct : List Pat -> List Pat -> List Pat
    distinct acc [] = acc
    distinct acc (p :: ps) 
       = if elemBy sameCase p acc 
            then distinct acc ps
            else distinct (p :: acc) ps

getScore : Defs -> Elem x (p :: ps) -> 
           List (NamedPats ns (p :: ps)) -> 
           Either CaseError (Elem x (p :: ps), Nat)
getScore defs prf npss 
    = case sameType defs (mkEnv ns) npss of
           Left err => Left err
           Right _ => Right (prf, countDiff npss)

bestOf : Either CaseError (Elem p ps, Nat) -> 
         Either CaseError (Elem q ps, Nat) ->
         Either CaseError (x ** (Elem x ps, Nat))
bestOf (Left err) (Left _) = Left err
bestOf (Left _) (Right p) = Right (_ ** p)
bestOf (Right p) (Left _) = Right (_ ** p)
bestOf (Right (p, psc)) (Right (q, qsc))
    = Right (_ ** (p, psc))
         -- at compile time, left to right helps coverage check
         -- (by refining types, so we know the type of the thing we're
         -- discriminating on)
         -- TODO: At run time pick most distinct, as below?
--     if psc >= qsc
--          then Just (_ ** (p, psc))
--          else Just (_ ** (q, qsc))

pickBest : Defs -> List (NamedPats ns (p :: ps)) -> 
           Either CaseError (x ** (Elem x (p :: ps), Nat))
pickBest {ps = []} defs npss 
    = if samePat npss
         then pure (_ ** (Here, 0))
         else do el <- getScore defs Here npss
                 pure (_ ** el)
pickBest {ps = q :: qs} defs npss 
    = -- Pick the leftmost thing with all constructors in the same family,
      -- or all variables, or all the same type constructor
      if samePat npss
         then pure (_ ** (Here, 0))
         else
            case pickBest defs (map tail npss) of
                 Left err => 
                    do el <- getScore defs Here npss
                       pure (_ ** el)
                 Right (_ ** (var, score)) =>
                    bestOf (getScore defs Here npss) (Right (There var, score))

-- Pick the next variable to inspect from the list of LHSs.
-- Choice *must* be the same type family, so pick the leftmost argument
-- where this applies.
pickNext : Defs -> List (NamedPats ns (p :: ps)) -> 
           Either CaseError (x ** Elem x (p :: ps))
pickNext defs npss 
   = case pickBest defs npss of
          Left err => Left err
          Right (_ ** (best, _)) => Right (_ ** best)

moveFirst : (el : Elem x ps) -> NamedPats ns ps ->
            NamedPats ns (x :: dropElem ps el)
moveFirst el nps = getPat el nps :: dropPat el nps

shuffleVars : (el : Elem x todo) -> PatClause vars todo ->
              PatClause vars (x :: dropElem todo el)
shuffleVars el (MkPatClause pvars lhs rhs) = MkPatClause pvars (moveFirst el lhs) rhs

{- 'match' does the work of converting a group of pattern clauses into
   a case tree, given a default case if none of the clauses match -}

mutual
  {- 'PatClause' contains a list of patterns still to process (that's the 
     "todo") and a right hand side with the variables we know about "vars".
     So "match" builds the remainder of the case tree for
     the unprocessed patterns. "err" is the tree for when the patterns don't
     cover the input (i.e. the "fallthrough" pattern, which at the top
     level will be an error). -}
  match : Defs -> Phase ->
          List (PatClause vars todo) -> (err : Maybe (CaseTree vars)) -> 
         StateT Int (Either CaseError) (CaseTree vars)
  -- Before 'partition', reorder the arguments so that the one we
  -- inspect next has a concrete type that is the same in all cases, and
  -- has the most distinct constructors (via pickNext)
  match {todo = (_ :: _)} defs phase clauses err 
      = case pickNext defs (map getNPs clauses) of
             Left err => lift $ Left err
             Right (_ ** next) =>
                let clauses' = map (shuffleVars next) clauses
                    ps = partition phase clauses' in
                    maybe (pure (Unmatched "No clauses"))
                          pure
                          !(mixture defs phase ps err)
  match {todo = []} defs phase [] err 
       = maybe (pure (Unmatched "No patterns"))
               pure err
  match {todo = []} defs phase ((MkPatClause pvars [] rhs) :: _) err 
       = pure $ STerm rhs

  caseGroups : Defs -> Phase ->
               Elem pvar vars -> Term vars ->
               List (Group vars todo) -> Maybe (CaseTree vars) ->
               StateT Int (Either CaseError) (CaseTree vars)
  caseGroups {vars} defs phase el ty gs errorCase
      = do g <- altGroups gs
           pure (Case el (resolveRefs vars ty) g)
    where
      altGroups : List (Group vars todo) -> 
                  StateT Int (Either CaseError) (List (CaseAlt vars))
      altGroups [] = maybe (pure []) 
                           (\e => pure [DefaultCase e]) 
                           errorCase
      altGroups (ConGroup {newargs} cn tag rest :: cs) 
          = do crest <- match defs phase rest (map (weakenNs newargs) errorCase)
               cs' <- altGroups cs
               pure (ConCase cn tag newargs crest :: cs')
      altGroups (ConstGroup c rest :: cs)
          = do crest <- match defs phase rest errorCase
               cs' <- altGroups cs
               pure (ConstCase c crest :: cs')

  conRule : Defs -> Phase ->
            List (PatClause vars (a :: todo)) ->
            Maybe (CaseTree vars) -> 
            StateT Int (Either CaseError) (CaseTree vars)
  conRule defs phase [] err = maybe (pure (Unmatched "No constructor clauses")) pure err 
  -- ASSUMPTION, not expressed in the type, that the patterns all have
  -- the same variable (pprf) for the first argument. If not, the result
  -- will be a broken case tree... so we should find a way to express this
  -- in the type if we can.
  conRule {a} defs phase cs@(MkPatClause pvars (MkInfo pat pprf fty :: pats) rhs :: rest) err 
      = do let refinedcs = map (substInClause defs) cs
           groups <- groupCons defs pvars refinedcs
           ty <- case fty of
                      Known _ t => pure t
                      _ => lift $ Left UnknownType
           caseGroups defs phase pprf ty groups err

  varRule : Defs -> Phase ->
            List (PatClause vars (a :: todo)) ->
            Maybe (CaseTree vars) -> 
            StateT Int (Either CaseError) (CaseTree vars)
  varRule {vars} {a} defs phase cs err 
      = do let alts' = map updateVar cs
           match defs phase alts' err
    where
      updateVar : PatClause vars (a :: todo) -> PatClause vars todo
      -- replace the name with the relevant variable on the rhs
      updateVar (MkPatClause pvars (MkInfo (PVar n) prf fty :: pats) rhs)
          = MkPatClause (n :: pvars) 
                        (substInPats defs a (Local Nothing prf) pats)
                        (substName n (Local Nothing prf) rhs)
      -- match anything, name won't appear in rhs but need to update
      -- LHS pattern types based on what we've learned
      updateVar (MkPatClause pvars (MkInfo pat prf fty :: pats) rhs)
          = MkPatClause pvars (substInPats defs a (mkTerm vars pat) pats) rhs

  mixture : {ps : List (PatClause vars (a :: todo))} ->
            Defs -> Phase ->
            Partitions ps -> 
            Maybe (CaseTree vars) -> 
            StateT Int (Either CaseError) (Maybe (CaseTree vars))
  mixture defs phase (ConClauses cs rest) err 
      = do fallthrough <- mixture defs phase rest err
           pure (Just !(conRule defs phase cs fallthrough))
  mixture defs phase (VarClauses vs rest) err 
      = do fallthrough <- mixture defs phase rest err
           pure (Just !(varRule defs phase vs fallthrough))
  mixture defs {a} {todo} phase NoClauses err 
      = pure err

mkPatClause : Defs ->
              (args : List Name) -> ClosedTerm -> (List Pat, ClosedTerm) ->
              Either CaseError (PatClause args args)
mkPatClause defs args ty (ps, rhs) 
    = maybe (Left DifferingArgNumbers)
            (\eq => 
               let nty = nf defs [] ty in
                 Right (MkPatClause [] (mkNames args ps eq (Just nty))
                    (rewrite sym (appendNilRightNeutral args) in 
                             (weakenNs args rhs))))
            (checkLengthMatch args ps)
  where
    mkNames : (vars : List Name) -> (ps : List Pat) -> 
              LengthMatch vars ps -> Maybe (NF []) ->
              NamedPats vars vars
    mkNames [] [] NilMatch fty = []
    mkNames (arg :: args) (p :: ps) (ConsMatch eq) fty
        = let fa_tys = case fty of
                            Nothing => (Nothing, Unknown)
                            Just (NBind _ (Pi c _ farg) fsc) => 
                                (Just (fsc (toClosure defaultOpts [] (Ref Bound arg))),
                                   Known c (embed {more = arg :: args} 
                                             (quote initCtxt [] farg)))
                            Just t => 
                                (Nothing, 
                                   Stuck (embed {more = arg :: args} 
                                             (quote initCtxt [] t))) in
              MkInfo p Here (snd fa_tys)
                    :: weaken (mkNames args ps eq 
                             (fst fa_tys)) 

export
patCompile : Defs -> Phase ->
             ClosedTerm -> List (List Pat, ClosedTerm) -> 
             Maybe (CaseTree []) ->
             Either CaseError (args ** CaseTree args)
patCompile defs phase ty [] def 
    = maybe (pure ([] ** Unmatched "No definition"))
            (\e => pure ([] ** e))
            def
patCompile defs phase ty (p :: ps) def 
    = do let ns = getNames 0 (fst p)
         pats <- traverse (mkPatClause defs ns ty) (p :: ps)
         (cases, _) <- runStateT (match defs phase pats 
                                    (rewrite sym (appendNilRightNeutral ns) in
                                             map (weakenNs ns) def)) 0
         pure (_ ** cases)
  where
    getNames : Int -> List Pat -> List Name
    getNames i [] = []
    getNames i (x :: xs) = MN "arg" i :: getNames (i + 1) xs

toPatClause : annot -> Name -> (ClosedTerm, ClosedTerm) ->
              Core annot (List Pat, ClosedTerm)
toPatClause loc n (lhs, rhs) with (unapply lhs)
  toPatClause loc n (apply (Ref Func fn) args, rhs) | ArgsList 
      = case nameEq n fn of
             Nothing => throw (GenericMsg loc ("Wrong function name in pattern LHS " ++ show (n, fn)))
             Just Refl => pure (map argToPat args, rhs)
  toPatClause loc n (apply f args, rhs) | ArgsList 
      = throw (GenericMsg loc "Not a function name in pattern LHS")


-- Assumption (given 'ClosedTerm') is that the pattern variables are
-- explicitly named. We'll assign de Bruijn indices when we're done, and
-- the names of the top level variables we created are returned in 'args'
export
simpleCase : {auto x : Ref Ctxt Defs} ->
             annot -> Phase -> Name -> ClosedTerm -> (def : Maybe (CaseTree [])) ->
             (clauses : List (ClosedTerm, ClosedTerm)) ->
             Core annot (args ** CaseTree args)
simpleCase loc phase fn ty def clauses 
    = do ps <- traverse (toPatClause loc fn) clauses
         defs <- get Ctxt
         case patCompile defs phase ty ps def of
              Left err => throw (CaseCompile loc fn err)
              Right ok => pure ok

export
getPMDef : {auto x : Ref Ctxt Defs} ->
           annot -> Phase -> Name -> ClosedTerm -> List Clause -> 
           Core annot (args ** CaseTree args)
-- If there's no clauses, make a definition with the right number of arguments
-- for the type, which we can use in coverage checking to ensure that one of
-- the arguments has an empty type
getPMDef loc phase fn ty []
    = do defs <- get Ctxt
         pure (getArgs 0 (nf defs [] ty) ** Unmatched "No clauses")
  where
    getArgs : Int -> NF [] -> List Name
    getArgs i (NBind x (Pi _ _ _) sc)
        = MN "arg" i :: getArgs i (sc (toClosure defaultOpts [] Erased))
    getArgs i _ = []
getPMDef loc phase fn ty clauses
    = do defs <- get Ctxt
         let cs = map (toClosed defs) clauses
         simpleCase loc phase fn ty Nothing cs
  where
    close : Defs ->
            Int -> (plets : Bool) -> Env Term vars -> Term vars -> ClosedTerm
    close defs i plets [] tm = tm
    close defs i True (PLet c val ty :: bs) tm 
		    = close defs (i + 1) True bs 
                (Bind (MN "pat" i) 
                    (Let c (normalise defs bs val) ty) (renameTop _ tm))
    close defs i True (Let c val ty :: bs) tm 
		    = close defs (i + 1) True bs 
                (Bind (MN "pat" i) 
                      (Let c (normalise defs bs val) ty) (renameTop _ tm))
    close defs i plets (b :: bs) tm 
        = close defs (i + 1) plets bs (subst (Ref Bound (MN "pat" i)) tm)

    toClosed : Defs -> Clause -> (ClosedTerm, ClosedTerm)
    toClosed defs (MkClause env lhs rhs) 
          = (close defs 0 False env lhs, close defs 0 True env rhs)

