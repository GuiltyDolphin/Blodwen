module TTImp.Elab.State

import Core.CaseTree
import Core.Context
import Core.Metadata
import Core.Normalise
import Core.TT
import Core.Unify

import TTImp.TTImp

import Data.List
import Data.CSet

-- How the elaborator should deal with IBindVar:
-- * NONE: IBindVar is not valid (rhs of an definition, top level expression)
-- * PI rig: Bind implicits as Pi, in the appropriate scope, and bind
--           any additional holes, with given multiplicity
public export
data ImplicitMode = NONE | PI RigCount | PATTERN

public export
data ElabMode = InType | InLHS RigCount | InExpr

export
Eq ElabMode where
  InType == InType = True
  (InLHS c) == (InLHS c') = c == c'
  InExpr == InExpr = True
  _ == _ = False

data BoundVar : List Name -> Type where
  MkBoundVar : Term outer -> Term outer -> BoundVar (vars ++ outer)

public export
record EState (vars : List Name) where
  constructor MkElabState
  -- The outer environment in which we're running the elaborator. Things here should
  -- be considered parametric as far as case expression elaboration goes, and are
  -- the only things that unbound implicits can depend on
  outerEnv : Env Term outer
  subEnv : SubVars outer vars
  boundNames : List (Name, (Term vars, Term vars))
                  -- implicit pattern/type variable bindings and the 
                  -- term/type they elaborated to
  toBind : List (Name, (Term vars, Term vars))
                  -- implicit pattern/type variables which haven't been
                  -- bound yet.
  bindIfUnsolved : List (Name, (vars' ** (Env Term vars', Term vars', Term vars', SubVars outer vars'))) 
                  -- names to add as unbound implicits if they are still holes
                  -- when unbound implicits are added
  lhsPatVars : List String
                  -- names which we've bound in elab mode InLHS (i.e. not
                  -- in a dot pattern). We keep track of this because every
                  -- occurrence other than the first needs to be dotted
  allPatVars : List Name -- All pattern variables, which need to be cleared after elaboration
  asVariables : List (Name, RigCount) -- Names bound in @-patterns
  implicitsUsed : List (Maybe Name)
                            -- explicitly given implicits which have been used
                            -- in the current application (need to keep track, as
                            -- they may not be given in the same order as they are 
                            -- needed in the type)
  linearUsed : List (x ** Elem x vars) -- Rig1 bound variables used in the term so far
  holesMade : List Name -- Explicit hole names used in the term so far
  defining : Name -- Name of thing we're currently defining

public export
Elaborator : Type -> Type
Elaborator annot
    = {vars : List Name} ->
      Ref Ctxt Defs -> Ref UST (UState annot) ->
      Ref ImpST (ImpState annot) -> Ref Meta (Metadata annot) ->
      (incase : Bool) ->
      Env Term vars -> NestedNames vars -> 
      ImpDecl annot -> Core annot ()

-- Expected type of an expression
public export
data ExpType : Type -> Type where
     Unknown : ExpType a -- expected type is unknown
     FnType : List (Name, a) -> a -> ExpType a 
        -- a function with given argument types. We do it this way because we
        -- don't know multiplicities of the arguments, so we can't use unification
        -- directly.
        -- An expected type is considered 'known' if it's a FnType []

export
expty : Lazy b -> Lazy (a -> b) -> ExpType a -> b
expty u fn (FnType [] t) = fn t
expty u fn _ = u

export
Functor ExpType where
  map f Unknown = Unknown
  map f (FnType ns ret) = FnType (map (\x => (fst x, f (snd x))) ns) (f ret)

export
Show a => Show (ExpType a) where
  show Unknown = "Unknown type"
  show (FnType [] ret) = show ret
  show (FnType args ret) = show args ++ " -> " ++ show ret

public export
record ElabInfo annot where
  constructor MkElabInfo
  topLevel : Bool -- at the top level of a type sig (i.e not in a higher order type)
  implicitMode : ImplicitMode
  elabMode : ElabMode
  implicitsGiven : List (Maybe Name, RawImp annot)
  lamImplicits : List (Maybe Name, RawImp annot)
  dotted : Bool -- are we under a dot pattern? (IMustUnify)

export
initElabInfo : ImplicitMode -> ElabMode -> ElabInfo annot
initElabInfo imp elab = MkElabInfo True imp elab [] [] False

-- A label for the internal elaborator state
export
data EST : Type where

export
initEStateSub : Name -> Env Term outer -> SubVars outer vars -> EState vars
initEStateSub n env sub = MkElabState env sub [] [] [] [] [] [] [] [] [] n

export
initEState : Name -> Env Term vars -> EState vars
initEState n env = initEStateSub n env SubRefl

export
updateEnv : Env Term new -> SubVars new vars -> 
            List (Name, (vars' ** (Env Term vars', Term vars', Term vars', SubVars new vars'))) ->
            EState vars -> EState vars
updateEnv env sub bif st
    = MkElabState env sub
                  (boundNames st) (toBind st) bif
                  (lhsPatVars st) (allPatVars st) (asVariables st)
                  (implicitsUsed st) (linearUsed st)
                  (holesMade st) (defining st)

export
addBindIfUnsolved : Name -> Env Term vars -> Term vars -> Term vars ->
                    EState vars -> EState vars
addBindIfUnsolved hn env tm ty st
    = MkElabState (outerEnv st) (subEnv st)
                  (boundNames st) (toBind st) 
                  ((hn, (_ ** (env, tm, ty, subEnv st))) :: bindIfUnsolved st)
                  (lhsPatVars st) (allPatVars st) (asVariables st)
                  (implicitsUsed st) (linearUsed st)
                  (holesMade st) (defining st)

clearBindIfUnsolved : EState vars -> EState vars
clearBindIfUnsolved st
    = MkElabState (outerEnv st) (subEnv st)
                  (boundNames st) (toBind st) []
                  (lhsPatVars st) (allPatVars st) (asVariables st)
                  (implicitsUsed st) (linearUsed st)
                  (holesMade st) (defining st)

-- Convenient way to record all of the elaborator state, for the times
-- we need to backtrack
export
AllState : List Name -> Type -> Type
AllState vars annot = (Defs, UState annot, EState vars, ImpState annot, Metadata annot)

export
getAllState : {auto c : Ref Ctxt Defs} -> {auto u : Ref UST (UState annot)} ->
              {auto e : Ref EST (EState vars)} -> {auto i : Ref ImpST (ImpState annot)} ->
              {auto m : Ref Meta (Metadata annot)} ->
              Core annot (AllState vars annot)
getAllState
    = do ctxt <- get Ctxt
         ust <- get UST
         est <- get EST
         ist <- get ImpST
         mst <- get Meta
         pure (ctxt, ust, est, ist, mst)

export
putAllState : {auto c : Ref Ctxt Defs} -> {auto u : Ref UST (UState annot)} ->
           {auto e : Ref EST (EState vars)} -> {auto i : Ref ImpST (ImpState annot)} ->
           {auto m : Ref Meta (Metadata annot)} ->
           AllState vars annot -> Core annot ()
putAllState (ctxt, ust, est, ist, mst)
    = do put Ctxt ctxt
         put UST ust
         put EST est
         put ImpST ist
         put Meta mst

export
getState : {auto c : Ref Ctxt Defs} -> {auto u : Ref UST (UState annot)} ->
           {auto i : Ref ImpST (ImpState annot)} ->
           Core annot (Defs, UState annot, ImpState annot)
getState
    = do ctxt <- get Ctxt
         ust <- get UST
         ist <- get ImpST
         pure (ctxt, ust, ist)

export
putState : {auto c : Ref Ctxt Defs} -> {auto u : Ref UST (UState annot)} ->
           {auto i : Ref ImpST (ImpState annot)} ->
           (Defs, UState annot, ImpState annot)-> Core annot ()
putState (ctxt, ust, ist)
    = do put Ctxt ctxt
         put UST ust
         put ImpST ist

export
inTmpState : {auto c : Ref Ctxt Defs} -> {auto u : Ref UST (UState annot)} ->
             {auto i : Ref ImpST (ImpState annot)} ->
             Core annot a -> Core annot a
inTmpState p
    = do st <- getState
         p' <- p
         putState st
         pure p'

export
saveImps : {auto e : Ref EST (EState vars)} -> Core annot (List (Maybe Name))
saveImps
    = do est <- get EST
         put EST (record { implicitsUsed = [] } est)
         pure (implicitsUsed est)

export
restoreImps : {auto e : Ref EST (EState vars)} -> List (Maybe Name) -> Core annot ()
restoreImps imps
    = do est <- get EST
         put EST (record { implicitsUsed = imps } est)

export
usedImp : {auto e : Ref EST (EState vars)} -> Maybe Name -> Core annot ()
usedImp imp
    = do est <- get EST
         put EST (record { implicitsUsed $= (imp :: ) } est)

-- Check that explicitly given implicits that we've used are allowed in the
-- the current application
export
checkUsedImplicits : {auto e : Ref EST (EState vars)} ->
                     annot -> Env Term vars -> ElabMode ->
                     List (Maybe Name) -> 
                     List (Maybe Name, RawImp annot) -> Term vars -> Core annot ()
checkUsedImplicits loc env mode used [] tm = pure ()
checkUsedImplicits loc env mode used given tm
    = let unused = filter (notUsed mode) given in
          case unused of
               [] => -- remove the things which were given, and are now part of
                     -- an application, from the 'implicitsUsed' list, because
                     -- we've now verified that they were used correctly.
                     restoreImps (filter (\x => not (x `elem` map fst given)) used)
               ((Just n, _) :: _) => throw (InvalidImplicit loc env n tm)
               ((Nothing, _) :: _) => throw (GenericMsg loc "No auto implicit here")
  where
    notUsed : ElabMode -> (Maybe Name, RawImp annot) -> Bool
    notUsed (InLHS _) (n, IAs _ _ (Implicit _)) = False -- added by elaborator, ignore it
    notUsed _ (x, _) = not (x `elem` used)

export
weakenedEState : {auto e : Ref EST (EState vs)} ->
                 Core annot (Ref EST (EState (n :: vs)))
weakenedEState
    = do est <- get EST
         e' <- newRef EST (MkElabState (outerEnv est)
                                       (DropCons (subEnv est))
                                       (map wknTms (boundNames est))
                                       (map wknTms (toBind est))
                                       (bindIfUnsolved est)
                                       (lhsPatVars est)
                                       (allPatVars est)
                                       (asVariables est)
                                       (implicitsUsed est)
                                       (map wknLoc (linearUsed est))
                                       (holesMade est)
                                       (defining est))
         pure e'
  where
    wknLoc : (x ** Elem x vs) -> (x ** Elem x (n :: vs))
    wknLoc (_ ** p) = (_ ** There p)

    wknTms : (Name, (Term vs, Term vs)) -> 
             (Name, (Term (n :: vs), Term (n :: vs)))
    wknTms (f, (x, y)) = (f, (weaken x, weaken y))

-- remove the outermost variable from the unbound implicits which have not
-- yet been bound. If it turns out to depend on it, that means it can't
-- be bound at the top level, which is an error.
export
strengthenedEState : {auto e : Ref EST (EState (n :: vs))} ->
                     {auto c : Ref Ctxt Defs} ->
                     (top : Bool) -> annot -> Env Term (n :: vs) ->
                     Core annot (EState vs)
-- strengthenedEState True loc env 
--     = do est <- get EST
--          pure (initEState (defining est))
strengthenedEState {n} {vs} _ loc env
    = do est <- get EST
         defs <- get Ctxt
         bns <- traverse (strTms defs) (boundNames est)
         todo <- traverse (strTms defs) (toBind est)
         let lvs = mapMaybe dropTop (linearUsed est)
         svs <- dropSub (subEnv est)
         pure (MkElabState (outerEnv est)
                           svs
                           bns todo (bindIfUnsolved est)
                                    (lhsPatVars est)
                                    (allPatVars est)
                                    (asVariables est)
                                    (implicitsUsed est) 
                                    lvs
                                    (holesMade est)
                                    (defining est))
  where
    dropSub : SubVars xs (y :: ys) -> Core annot (SubVars xs ys)
    dropSub (DropCons sub) = pure sub
    dropSub _ = throw (InternalError "Badly formed weakened environment")

    -- Remove any instance of the top level local variable from an
    -- application. Fail if it turns out to be necessary.
    -- NOTE: While this isn't strictly correct given the type of the hole
    -- which stands for the unbound implicits, it's harmless because we
    -- never actualy *use* that hole - this process is only to ensure that the
    -- unbound implicit doesn't depend on any variables it doesn't have
    -- in scope.
    removeArgVars : List (Term (n :: vs)) -> Maybe (List (Term vs))
    removeArgVars [] = pure []
    removeArgVars (Local r (There p) :: args) 
        = do args' <- removeArgVars args
             pure (Local r p :: args')
    removeArgVars (Local r Here :: args) 
        = removeArgVars args
    removeArgVars (a :: args)
        = do a' <- shrinkTerm a (DropCons SubRefl)
             args' <- removeArgVars args
             pure (a' :: args')

    removeArg : Term (n :: vs) -> Maybe (Term vs)
    removeArg tm with (unapply tm)
      removeArg (apply f args) | ArgsList 
          = do args' <- removeArgVars args
               f' <- shrinkTerm f (DropCons SubRefl)
               pure (apply f' args')

    strTms : Defs -> (Name, (Term (n :: vs), Term (n :: vs))) -> 
             Core annot (Name, (Term vs, Term vs))
    strTms defs (f, (x, y))
        = let xnf = normaliseHoles defs env x
              ynf = normaliseHoles defs env y in
              case (removeArg xnf, shrinkTerm ynf (DropCons SubRefl)) of
               (Just x', Just y') => pure (f, (x', y'))
               _ => throw (GenericMsg loc ("Invalid unbound implicit " ++ 
                               show f ++ " " ++ show xnf ++ " : " ++ show ynf))

    dropTop : (x ** Elem x (n :: vs)) -> Maybe (x ** Elem x vs)
    dropTop (_ ** Here) = Nothing
    dropTop (_ ** There p) = Just (_ ** p)

elemEmbedSub : SubVars small vars -> Elem x small -> Elem x vars
elemEmbedSub SubRefl y = y
elemEmbedSub (DropCons prf) y = There (elemEmbedSub prf y)
elemEmbedSub (KeepCons prf) Here = Here
elemEmbedSub (KeepCons prf) (There later) = There (elemEmbedSub prf later)

embedSub : SubVars small vars -> Term small -> Term vars
embedSub sub (Local r prf) = Local r (elemEmbedSub sub prf)
embedSub sub (Ref x fn) = Ref x fn
embedSub sub (Bind x b tm) 
    = Bind x (assert_total (map (embedSub sub) b))
             (embedSub (KeepCons sub) tm)
embedSub sub (App f a) = App (embedSub sub f) (embedSub sub a)
embedSub sub (PrimVal x) = PrimVal x
embedSub sub Erased = Erased
embedSub sub TType = TType

-- Make a hole for an unbound implicit in the outer environment
export
mkOuterHole : {auto e : Ref EST (EState vars)} ->
              {auto c : Ref Ctxt Defs} ->
              {auto e : Ref UST (UState annot)} ->
              annot -> Name -> Bool -> Env Term vars -> ExpType (Term vars) ->
              Core annot (Term vars, Term vars)
mkOuterHole {vars} loc n patvar topenv (FnType [] expected)
    = do est <- get EST
         let sub = subEnv est
         case shrinkTerm expected sub of
              -- Can't shrink so rely on unification with expected type later
              Nothing => mkOuterHole loc n patvar topenv Unknown
              Just exp' => 
                  do tm <- addBoundName loc n patvar (outerEnv est) exp'
                     pure (embedSub sub tm, embedSub sub exp')
mkOuterHole loc n patvar topenv _
    = do est <- get EST
         let sub = subEnv est
         let env = outerEnv est
         t <- addHole loc env TType "impty"
         let ty = mkConstantApp t env
         put EST (addBindIfUnsolved t topenv (embedSub sub ty) TType est)

         tm <- addBoundName loc n patvar env ty
         pure (embedSub sub tm, embedSub sub ty)

export
mkPatternHole : {auto e : Ref EST (EState vars)} ->
                {auto c : Ref Ctxt Defs} ->
                {auto e : Ref UST (UState annot)} ->
                annot -> Name -> Env Term vars -> ImplicitMode ->
                ExpType (Term vars) ->
                Core annot (Term vars, Term vars, Term vars)
mkPatternHole loc n env (PI _) exp
    = do (tm, exp) <- mkOuterHole loc n True env exp
         pure (tm, exp, exp)
mkPatternHole {vars} loc n topenv imode (FnType [] expected)
    = do est <- get EST
         let sub = subEnv est
         let env = outerEnv est
         case bindInner topenv expected sub of
              Nothing => mkPatternHole loc n topenv imode Unknown
              Just exp' =>
                  do tm <- addBoundName loc n True env exp'
                     pure (apply (embedSub sub tm) (mkArgs sub), 
                           expected,
                           embedSub sub exp')
  where
    mkArgs : SubVars newvars vs -> List (Term vs)
    mkArgs SubRefl = []
    mkArgs (DropCons p) = Local Nothing Here :: map weaken (mkArgs p)
    mkArgs _ = []

    bindInner : Env Term vs -> Term vs -> SubVars newvars vs -> 
                Maybe (Term newvars)
    bindInner env ty SubRefl = Just ty
    bindInner {vs = x :: _} (b :: env) ty (DropCons p)
        = bindInner env (Bind x b ty) p
    bindInner _ _ _ = Nothing

mkPatternHole loc n env _ _
    = throw (InternalError "Not yet")

-- Clear the 'toBind' list, except for the names given
export
clearToBind : {auto e : Ref EST (EState vs)} ->
              (excepts : List Name) -> Core annot ()
clearToBind excepts
    = do est <- get EST
         put EST (record { toBind $= filter (\x => fst x `elem` excepts) } 
                         (clearBindIfUnsolved est))

export
dropTmIn : List (a, (c, d)) -> List (a, d)
dropTmIn = map (\ (n, (_, t)) => (n, t))

getHoleType : Defs -> Env Term vars ->
              Name -> List (Term vars) -> Maybe (Name, Term vars)
getHoleType {vars} defs env n args
    = do gdef <- lookupGlobalExact n (gamma defs)
         case definition gdef of
              Hole locs _ _ =>
                let nty = nf defs env (embed (type gdef)) in
                    Just (n, quote defs env (applyArgs locs nty args))
              _ => Nothing
  where
    applyArgs : Nat -> NF vars -> List (Term vars) -> NF vars
    applyArgs Z ty args = ty
    applyArgs (S k) (NBind x (Pi _ _ _) scf) (arg :: args)
        = applyArgs k (scf (toClosure defaultOpts env arg)) args
    applyArgs (S k) ty _ = ty

export
convert : {auto c : Ref Ctxt Defs} -> {auto u : Ref UST (UState annot)} ->
          {auto e : Ref EST (EState vars)} ->
          annot -> ElabMode -> Env Term vars -> NF vars -> NF vars -> 
          Core annot (List Name)
convert loc elabmode env x y 
    = let umode = case elabmode of
                       InLHS _ => InLHS
                       _ => InTerm in
          catch (do gam <- get Ctxt
                    log 10 $ "Unifying " ++ show (quote (noGam gam) env x) ++ " and " 
                                         ++ show (quote (noGam gam) env y)
                    hs <- getHoleNames 
                    vs <- unify umode loc env x y
                    hs' <- getHoleNames
                    when (isNil vs && (length hs' < length hs)) $ 
                       solveConstraints umode Normal
                    pure vs)
            (\err => do gam <- get Ctxt 
                        -- Try to solve any remaining constraints to see if it helps
                        -- the error message
                        catch (solveConstraints umode Normal)
                              (\err => pure ())
                        throw (WhenUnifying loc env
                                            (normaliseHoles gam env (quote (noGam gam) env x))
                                            (normaliseHoles gam env (quote (noGam gam) env y))
                                  err))

-- For any of the 'bindIfUnsolved' - these were added as holes during
-- elaboration, but are as yet unsolved, so create a pattern variable for
-- them and unify.
-- (This is only when we're in a mode that allows unbound implicits)
bindUnsolved : {auto c : Ref Ctxt Defs} -> {auto e : Ref EST (EState vars)} ->
               {auto u : Ref UST (UState annot)} ->
               annot -> ElabMode -> ImplicitMode -> Core annot ()
bindUnsolved loc elabmode NONE = pure ()
bindUnsolved {vars} loc elabmode _ 
    = do est <- get EST
         defs <- get Ctxt
         let bifs = bindIfUnsolved est
         log 10 $ "Bindable unsolved implicits: " ++ show (map fst bifs)
         traverse (mkImplicit defs (outerEnv est) (subEnv est)) (bindIfUnsolved est)
         pure ()
  where
    makeBoundVar : Name -> Env Term outer ->
                   SubVars outer vs -> SubVars outer vars ->
                   Term vs -> Core annot (Term vs)
    makeBoundVar n env sub subvars expected
        = case shrinkTerm expected sub of
               Nothing => throw (GenericMsg loc ("Can't bind implicit of type " ++ show expected))
               Just exp' => 
                    do impn <- genName (nameRoot n)
                       tm <- addBoundName loc impn False env exp'
                       est <- get EST
                       put EST (record { toBind $= ((impn, (embedSub subvars tm, 
                                                            embedSub subvars exp')) ::) } est)
                       pure (embedSub sub tm)

    mkImplicit : Defs -> Env Term outer -> SubVars outer vars ->
                 (Name, (vars' ** 
                     (Env Term vars', Term vars', Term vars', SubVars outer vars'))) -> 
                 Core annot ()
    mkImplicit defs outerEnv subEnv (n, (vs ** (env, tm, exp, sub)))
        = case lookupDefExact n (gamma defs) of
               Just (Hole locs _ _) => 
                    do bindtm <- makeBoundVar n outerEnv
                                              sub subEnv
                                              (normaliseHoles defs env exp)
                       log 5 $ "Added unbound implicit " ++ show bindtm
                       unify (case elabmode of
                                   InLHS _ => InLHS
                                   _ => InTerm)
                             loc env tm bindtm
                       pure ()
               _ => pure ()

-- 'toBind' are the names which are to be implicitly bound (pattern bindings and
-- unbound implicits).
-- Return the names in the order they should be bound: i.e. respecting
-- dependencies between types, and putting @-patterns last because their
-- value is determined from the patterns
export
getToBind : {auto c : Ref Ctxt Defs} -> {auto e : Ref EST (EState vars)} ->
            {auto u : Ref UST (UState annot)} ->
            annot -> ElabMode -> ImplicitMode ->
            Env Term vars -> (excepts : List Name) -> Term vars ->
            Core annot (List (Name, Term vars))
getToBind loc elabmode NONE ent excepts toptm = pure []
getToBind {vars} loc elabmode impmode env excepts toptm
    = do solveConstraints (case elabmode of
                                InLHS _ => InLHS
                                _ => InTerm) Normal
         gam <- get Ctxt
         log 1 $ "Binding in " ++ show (normaliseHoles gam env toptm)
      
         bindUnsolved loc elabmode impmode
         solveConstraints (case elabmode of
                                InLHS _ => InLHS
                                _ => InTerm) Normal
         dumpConstraints 2 False

         gam <- get Ctxt
         est <- get EST
         ust <- get UST

         let tob = reverse $ filter (\x => not (fst x `elem` excepts)) $
                             toBind est

         log 10 $ "With holes " ++ show (map snd (holes ust))
         res <- normImps gam [] tob
         let hnames = map fst res
         log 10 $ "Sorting " ++ show res
         let ret = asLast (map fst (asVariables est)) (depSort hnames res)
         log 7 $ "Sorted implicits " ++ show ret
         pure ret
  where
    -- put the @-pattern bound names last (so that we have the thing they're
    -- equal to bound first)
    asLast : List Name -> List (Name, Term vars) -> 
                          List (Name, Term vars)
    asLast asvars ns 
        = filter (\p => not (fst p `elem` asvars)) ns ++
          filter (\p => fst p `elem` asvars) ns

    normImps : Defs -> List Name -> List (Name, Term vars, Term vars) -> 
               Core annot (List (Name, Term vars))
    normImps gam ns [] = pure []
    normImps gam ns ((PV n i, tm, ty) :: ts) 
        = if PV n i `elem` ns
             then normImps gam ns ts
             else do rest <- normImps gam (PV n i :: ns) ts
                     pure ((PV n i, normaliseHoles gam env ty) :: rest)
    normImps gam ns ((n, tm, ty) :: ts)
        = case (getFnArgs (normaliseHoles gam env tm)) of
             (Ref nt n', args) => 
                do hole <- isCurrentHole n'
                   if hole && not (n' `elem` ns)
                      then do rest <- normImps gam (n' :: ns) ts
                              pure ((n', normaliseHoles gam env ty) :: rest)
                      -- unified to something concrete, so no longer relevant, drop it
                      else normImps gam ns ts
             _ => do rest <- normImps gam (n :: ns) ts
                     pure ((n, normaliseHoles gam env ty) :: rest)
    
    -- Insert the hole/binding pair into the list before the first thing
    -- which refers to it
    insert : (Name, Term vars) -> List Name -> List Name -> 
             List (Name, Term vars) -> 
             List (Name, Term vars)
    insert h ns sofar [] = [h]
    insert (hn, hty) ns sofar ((hn', hty') :: rest)
        = let used = filter (\n => elem n ns) (toList (getRefs hty')) in
              if hn `elem` used
                 then (hn, hty) :: (hn', hty') :: rest
                 else (hn', hty') :: 
                          insert (hn, hty) ns (hn' :: sofar) rest
    
    -- Sort the list of implicits so that each binding is inserted *after*
    -- all the things it depends on (assumes no cycles)
    depSort : List Name -> List (Name, Term vars) -> 
              List (Name, Term vars)
    depSort hnames [] = []
    depSort hnames (h :: hs) = insert h hnames [] (depSort hnames hs)

substPLet : RigCount -> (n : Name) -> (val : Term vars) -> (ty : Term vars) ->
            Term (n :: vars) -> Term (n :: vars) -> (Term vars, Term vars)
substPLet rig n tm ty sctm scty
    = (Bind n (PLet rig tm ty) sctm, Bind n (PLet rig tm ty) scty)

normaliseHolesScope : Defs -> Env Term vars -> Term vars -> Term vars
normaliseHolesScope defs env (Bind n b sc) 
    = Bind n b (normaliseHolesScope defs 
               -- use Lam because we don't want it reducing in the scope
               (Lam (multiplicity b) Explicit (binderType b) :: env) sc)
normaliseHolesScope defs env tm = normaliseHoles defs env tm

-- Bind implicit arguments, returning the new term and its updated type
bindImplVars : ImplicitMode ->
               Defs ->
               Env Term vars ->
               List (Name, Term vars) ->
               List (Name, RigCount) ->
               Term vars -> Term vars -> (Term vars, Term vars)
bindImplVars NONE gam env args asvs scope scty = (scope, scty)
bindImplVars mode gam env imps asvs scope scty = doBinds 0 env imps scope scty
  where
    -- Replace the name applied to the given number of arguments 
    -- with another term
    repName : Name -> Nat -> (new : Term vars) -> Term vars -> Term vars
    repName old locs new (Local r p) = Local r p
    repName old locs new (Ref nt fn)
        = case nameEq old fn of
               Nothing => Ref nt fn
               Just Refl => new
    repName old locs new (Bind y b tm) 
        = Bind y (assert_total (map (repName old locs new) b)) 
                 (repName old locs (weaken new) tm)
    repName old locs new (App fn arg) 
        = case getFnArgs (App fn arg) of
               (Ref nt fn', args) =>
                   if old == fn'
                      then apply new (map (repName old locs new) (drop locs args))
                      else apply (Ref nt fn')
                                 (map (repName old locs new) args)
               (fn', args) => apply (repName old locs new fn') 
                                    (map (repName old locs new) args)
    repName old locs new (PrimVal y) = PrimVal y
    repName old locs new Erased = Erased
    repName old locs new TType = TType
    
    doBinds : Int -> Env Term vars -> List (Name, Term vars) ->
              Term vars -> Term vars -> (Term vars, Term vars)
    doBinds i env [] scope scty = (scope, scty)
    doBinds i env ((n, ty) :: imps) scope scty
      = let (scope', ty') = doBinds (i + 1) env imps scope scty
            tmpN = MN "unb" i
            ndef = lookupDefExact n (gamma gam)
            locs = case ndef of
                        Just (Hole i _ _) => i
                        _ => 0
            repNameTm = repName n locs (Ref Bound tmpN) scope' 
            repNameTy = repName n locs (Ref Bound tmpN) ty'

            n' = dropNS n in
            case mode of
                 PATTERN =>
                    case ndef of
                         Just (PMDef _ _ _ _ _) =>
                            -- if n is an accessible pattern variable, bind it,
                            -- otherwise reduce it
                            case n of
                                 PV _ _ =>
                                    -- Need to apply 'n' to the surrounding environment in these cases!
                                    -- otherwise it won't work in nested defs...
                                    let tm = normaliseHolesScope gam env (applyTo (Ref Func n) env) 
                                        rig = maybe RigW id (lookup n asvs) in
                                        substPLet rig n' tm ty 
                                            (refToLocal Nothing tmpN n' repNameTm)
                                            (refToLocal Nothing tmpN n' repNameTy)

                                 _ => let tm = normaliseHolesScope gam env (applyTo (Ref Func n) env) in
                                      (subst tm
                                             (refToLocal Nothing tmpN n repNameTm),
                                       subst tm
                                             (refToLocal Nothing tmpN n repNameTy))
                         _ =>
                            (Bind n' (PVar RigW ty) (refToLocal Nothing tmpN n' repNameTm), 
                             Bind n' (PVTy RigW ty) (refToLocal Nothing tmpN n' repNameTy))
                 -- unless explicitly given, unbound implicits are Rig0
                 PI rig =>
                    case ndef of
                       Just (PMDef _ _ _ _ _) =>
                          let tm = normaliseHolesScope gam env (applyTo (Ref Func n) env) in
                              (subst tm (refToLocal Nothing tmpN n repNameTm),
                               subst tm (refToLocal Nothing tmpN n repNameTy))
                       _ => (Bind n' (Pi rig Implicit ty) (refToLocal Nothing tmpN n' repNameTm), ty')
                 _ => (Bind n' (Pi RigW Implicit ty) 
                            (refToLocal Nothing tmpN n' repNameTm), ty')

swapElemH : Elem p (x :: y :: ys) -> Elem p (y :: x :: ys)
swapElemH Here = There Here
swapElemH (There Here) = Here
swapElemH (There (There p)) = There (There p)

swapElem : {xs : List a} ->
           Elem p (xs ++ x :: y :: ys) -> Elem p (xs ++ y :: x :: ys)
swapElem {xs = []} prf = swapElemH prf
swapElem {xs = n :: ns} Here = Here
swapElem {xs = n :: ns} (There prf) = There (swapElem prf)

-- We've swapped two binders (in 'push' below) so we'd better swap the
-- corresponding references
swapVars : Term (vs ++ x :: y :: ys) -> Term (vs ++ y :: x :: ys)
swapVars (Local r prf) = Local r (swapElem prf)
swapVars (Ref nt n) = Ref nt n
swapVars {vs} (Bind x b sc) 
    = Bind x (map swapVars b) (swapVars {vs = x :: vs} sc)
swapVars (App fn arg) = App (swapVars fn) (swapVars arg)
swapVars (PrimVal t) = PrimVal t
swapVars Erased = Erased
swapVars TType = TType

-- Push an explicit pi binder as far into a term as it'll go. That is,
-- move it under implicit binders that don't depend on it, and stop
-- when hitting any non-implicit binder
push : (n : Name) -> Binder (Term vs) -> Term (n :: vs) -> Term vs
push n b tm@(Bind (PV x i) (Pi c Implicit ty) sc) -- only push past 'PV's
    = case shrinkTerm ty (DropCons SubRefl) of
           Nothing => -- needs explicit pi, do nothing
                      Bind n b tm
           Just ty' => Bind (PV x i) (Pi c Implicit ty') 
                            (push n (map weaken b) (swapVars {vs = []} sc))
push n b tm = Bind n b tm

-- Move any implicit arguments as far to the left as possible - this helps
-- with curried applications
-- We only do this for variables named 'PV', since they are the unbound
-- implicits, and we don't want to move any given by the programmer
liftImps : ImplicitMode -> (Term vars, Term vars) -> (Term vars, Term vars)
liftImps (PI _) (tm, TType) = (liftImps' tm, TType)
  where
    liftImps' : Term vars -> Term vars
    liftImps' (Bind (PV n i) (Pi c Implicit ty) sc) 
        = Bind (PV n i) (Pi c Implicit ty) (liftImps' sc)
    liftImps' (Bind n (Pi c p ty) sc)
        = push n (Pi c p ty) (liftImps' sc)
    liftImps' tm = tm
liftImps _ x = x

export
bindImplicits : ImplicitMode ->
                Defs -> Env Term vars ->
                List (Name, Term vars) ->
                List (Name, RigCount) ->
                Term vars -> Term vars -> (Term vars, Term vars)
bindImplicits NONE game env hs asvs tm ty = (tm, ty)
bindImplicits {vars} mode gam env hs asvs tm ty 
   = liftImps mode $ bindImplVars mode gam env (map nHoles hs) asvs tm ty
  where
    nHoles : (Name, Term vars) -> (Name, Term vars)
    nHoles (n, ty) = (n, normaliseHolesScope gam env ty)
   
export
bindTopImplicits : ImplicitMode -> Defs -> Env Term vars ->
                   List (Name, ClosedTerm) -> 
                   List (Name, RigCount) ->
                   Term vars -> Term vars ->
                   (Term vars, Term vars)
bindTopImplicits {vars} mode gam env hs asvs tm ty
    = bindImplicits mode gam env (map weakenVars hs) asvs tm ty
  where
    weakenVars : (Name, ClosedTerm) -> (Name, Term vars)
    weakenVars (n, tm) = (n, rewrite sym (appendNilRightNeutral vars) in
                                     weakenNs vars tm)

export
renameImplicits : Gamma -> Term vars -> Term vars
renameImplicits gam (Bind (PV n i) b sc) 
    = case lookupDefExact (PV n i) gam of
           Just (PMDef _ _ _ _ _) =>
--                 trace ("OOPS " ++ show n ++ " = " ++ show def) $
                    Bind n (map (renameImplicits gam) b)
                           (renameImplicits gam (renameTop n sc))
           _ => Bind n (map (renameImplicits gam) b)
                       (renameImplicits gam (renameTop n sc))
renameImplicits gam (Bind n b sc) 
    = Bind n (map (renameImplicits gam) b) (renameImplicits gam sc)
renameImplicits gam t = t

export
inventFnType : {auto c : Ref Ctxt Defs} -> {auto u : Ref UST (UState annot)} ->
               annot -> Env Term vars -> (bname : Name) ->
               Core annot (Term vars, Term (bname :: vars))
inventFnType loc env bname
    = do an <- genName "arg_type"
         scn <- genName "res_type"
         argTy <- addBoundName loc an False env TType
--          scTy <- addBoundName loc scn False (Pi RigW Explicit argTy :: env) TType
         scTy <- addBoundName loc scn False env TType
         pure (argTy, weaken scTy)

-- Given a raw term, collect the explicitly given implicits {x = tm} in the
-- top level application, and return an updated term without them
export
collectGivenImps : RawImp annot -> (RawImp annot, List (Maybe Name, RawImp annot))
collectGivenImps (IImplicitApp loc fn nm arg)
    = let (fn', args') = collectGivenImps fn in
          (fn', (nm, arg) :: args')
collectGivenImps (IApp loc fn arg)
    = let (fn', args') = collectGivenImps fn in
          (IApp loc fn' arg, args')
collectGivenImps tm = (tm, [])

-- try an elaborator, if it fails reset the state and return 'Left',
-- otherwise return 'Right'
export
tryError : {auto c : Ref Ctxt Defs} -> {auto e : Ref UST (UState annot)} ->
           {auto e : Ref EST (EState vars)} -> {auto i : Ref ImpST (ImpState annot)} ->
           {auto m : Ref Meta (Metadata annot)} ->
           Core annot a -> Core annot (Either (Error annot) a)
tryError elab 
    = do -- store the current state of everything
         st <- getAllState
         catch (do res <- elab 
                   pure (Right res))
               (\err => do -- reset the state
                           putAllState st
                           pure (Left err))

-- try one elaborator; if it fails, try another
export
try : {auto c : Ref Ctxt Defs} -> {auto u : Ref UST (UState annot)} ->
      {auto e : Ref EST (EState vars)} -> {auto i : Ref ImpST (ImpState annot)} ->
      {auto m : Ref Meta (Metadata annot)} ->
      Core annot a ->
      Core annot a ->
      Core annot a
try elab1 elab2
    = do Right ok <- tryError elab1
               | Left err => elab2
         pure ok

-- try one elaborator; if it fails, handle the error
export
handle : {auto c : Ref Ctxt Defs} -> {auto u : Ref UST (UState annot)} ->
         {auto e : Ref EST (EState vars)} -> {auto i : Ref ImpST (ImpState annot)} ->
         {auto m : Ref Meta (Metadata annot)} ->
         Core annot a ->
         (Error annot -> Core annot a) ->
         Core annot a
handle elab1 elab2
    = do -- store the current state of everything
         st <- getAllState
         catch elab1
               (\err => do -- reset the state
                           putAllState st
                           elab2 err)

-- try one (outer) elaborator; if it fails, handle the error. Doesn't
-- save the elaborator state!
export
handleClause
       : {auto c : Ref Ctxt Defs} -> {auto u : Ref UST (UState annot)} ->
         {auto i : Ref ImpST (ImpState annot)} ->
         Core annot a ->
         (Error annot -> Core annot a) ->
         Core annot a
handleClause elab1 elab2
    = do -- store the current state of everything
         st <- getState
         catch elab1
               (\err => do -- reset the state
                           putState st
                           elab2 err)

-- try all elaborators, return the results from the ones which succeed
-- and the corresponding elaborator state
export
successful : {auto c : Ref Ctxt Defs} -> {auto u : Ref UST (UState annot)} ->
             {auto e : Ref EST (EState vars)} -> {auto i : Ref ImpST (ImpState annot)} ->
             {auto m : Ref Meta (Metadata annot)} ->
             ElabMode -> List (Maybe Name, Core annot a) ->
             Core annot (List (Either (Maybe Name, Error annot)
                                      (a, AllState vars annot)))
successful elabmode [] = pure []
successful elabmode ((tm, elab) :: elabs)
    = do solveConstraints (case elabmode of
                                InLHS _ => InLHS
                                _ => InTerm) Normal
         init_st <- getAllState
         log 5 $ "Trying elaborator for " ++ show tm
         Right res <- tryError elab
               | Left err => do rest <- successful elabmode elabs
                                log 5 $ "Result for " ++ show tm ++ ": failure"
                                pure (Left (tm, err) :: rest)

         log 5 $ "Result for " ++ show tm ++ ": success"
         elabState <- getAllState -- save state at end of successful elab
         -- reinitialise state for next elabs
         putAllState init_st
         rest <- successful elabmode elabs
         pure (Right (res, elabState) :: rest)

export
exactlyOne : {auto c : Ref Ctxt Defs} -> {auto u : Ref UST (UState annot)} ->
             {auto e : Ref EST (EState vars)} -> {auto i : Ref ImpST (ImpState annot)} ->
             {auto m : Ref Meta (Metadata annot)} ->
             annot -> Env Term vars -> ElabMode ->
             List (Maybe Name, Core annot (Term vars, Term vars)) ->
             Core annot (Term vars, Term vars)
exactlyOne loc env elabmode [(tm, elab)] = elab
exactlyOne {vars} loc env elabmode all
    = do elabs <- successful elabmode all
         case rights elabs of
              [(res, state)] =>
                   do putAllState state
                      pure res
              rs => throw (altError (lefts elabs) rs)
  where
    normRes : ((Term vars, Term vars), AllState vars annot) -> Term vars
    normRes ((tm, _), thisst) = (normaliseHoles (fst thisst) env tm)

    -- If they've all failed, collect all the errors
    -- If more than one succeeded, report the ambiguity
    altError : List (Maybe Name, Error annot) -> List ((Term vars, Term vars), AllState vars annot) ->
               Error annot
    altError ls [] = AllFailed ls
    altError ls rs = AmbiguousElab loc env (map normRes rs)

export
anyOne : {auto c : Ref Ctxt Defs} -> {auto u : Ref UST (UState annot)} ->
         {auto e : Ref EST (EState vars)} -> {auto i : Ref ImpST (ImpState annot)} ->
         {auto m : Ref Meta (Metadata annot)} ->
         annot -> ElabMode ->
         List (Maybe Name, Core annot (Term vars, Term vars)) ->
         Core annot (Term vars, Term vars)
anyOne loc elabmode [] = throw (GenericMsg loc "All elaborators failed")
anyOne loc elabmode [(tm, elab)] = elab
anyOne loc elabmode ((tm, e) :: es) 
    = try (do solveConstraints (case elabmode of
                                     InLHS _ => InLHS
                                     _ => InTerm) Normal
              e) 
          (anyOne loc elabmode es)

