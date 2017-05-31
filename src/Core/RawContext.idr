module Core.RawContext

import Core.Context
import Core.Typecheck
import Core.Evaluate
import Core.TT

%default covering

public export
data RawTy : Type where
     MkRawTy : (n : Name) -> (ty : Raw) -> RawTy

public export
data RawData : Type where
     MkRawData : (tycon : RawTy) -> (datacons : List RawTy) -> RawData

public export
data RawClause : Type where
     MkRawClause : (pvars : List (Name, Raw)) ->
                   (lhs : Raw) -> (rhs : Raw) -> RawClause

public export
data RawFnDef : Type where
     MkRawFn : (n : Name) -> (ty : Raw) -> (clauses : List RawClause) ->
               RawFnDef

public export
data RawDecl = FnDecl RawFnDef
             | DataDecl RawData

using (CtxtManage m)
  addTyDecl : (ctxt : Var) -> (ty : RawTy) -> 
              ST m (Name, ClosedTerm) [ctxt ::: Defs]
  addTyDecl ctxt (MkRawTy n ty)
      = do tyc <- check ctxt [] ty TType
           addDef ctxt n (MkGlobalDef tyc Public None)
           pure (n, tyc)

  addFn : (ctxt : Var) -> (def : RawFnDef) -> ST m () [ctxt ::: Defs]

  addData : (ctxt : Var) -> (def : RawData) -> ST m () [ctxt ::: Defs]
  addData ctxt (MkRawData tycon datacons)
      = do (tn, tty) <- addTyDecl ctxt tycon
           cons <- mapST checkCon datacons
           gam <- getCtxt ctxt
           let def = MkData (MkCon tn (getArity gam [] tty) tty) cons
           addData ctxt Public def
    where
      checkCon : RawTy -> ST m Constructor [ctxt ::: Defs]
      checkCon (MkRawTy n ty) 
          = do tyc <- check ctxt [] ty TType
               gam <- getCtxt ctxt
               pure (MkCon n (getArity gam [] tyc) tyc)
