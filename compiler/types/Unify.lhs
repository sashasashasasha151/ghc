%
% (c) The University of Glasgow 2006
%

\begin{code}
{-# OPTIONS -fno-warn-tabs #-}
-- The above warning supression flag is a temporary kludge.
-- While working on this module you are encouraged to remove it and
-- detab the module (please do the detabbing in a separate patch). See
--     http://hackage.haskell.org/trac/ghc/wiki/Commentary/CodingStyle#TabsvsSpaces
-- for details

module Unify ( 
	-- Matching of types: 
	--	the "tc" prefix indicates that matching always
	--	respects newtypes (rather than looking through them)
	tcMatchTy, tcMatchTys, tcMatchTyX, 
	ruleMatchTyX, tcMatchPreds, 

	MatchEnv(..), matchList, 

	typesCantMatch,

        -- Side-effect free unification
        tcUnifyTys, BindFlag(..),
        niFixTvSubst, niSubstTvSet,

        ApartResult(..), tcApartTys

   ) where

#include "HsVersions.h"

import Var
import VarEnv
import VarSet
import Kind
import Type
import TyCon
import TypeRep
import Util
\end{code}


%************************************************************************
%*									*
		Matching
%*									*
%************************************************************************


Matching is much tricker than you might think.

1. The substitution we generate binds the *template type variables*
   which are given to us explicitly.

2. We want to match in the presence of foralls; 
	e.g 	(forall a. t1) ~ (forall b. t2)

   That is what the RnEnv2 is for; it does the alpha-renaming
   that makes it as if a and b were the same variable.
   Initialising the RnEnv2, so that it can generate a fresh
   binder when necessary, entails knowing the free variables of
   both types.

3. We must be careful not to bind a template type variable to a
   locally bound variable.  E.g.
	(forall a. x) ~ (forall b. b)
   where x is the template type variable.  Then we do not want to
   bind x to a/b!  This is a kind of occurs check.
   The necessary locals accumulate in the RnEnv2.


\begin{code}
-- avoid rewriting boilerplate by overloading:
class Unifiable t where
  match :: MatchEnv -> TvSubstEnv -> CvSubstEnv
        -> t -> t -> Maybe (TvSubstEnv, CvSubstEnv)
  unify :: TvSubstEnv -> CvSubstEnv -> t -> t -> UM (TvSubstEnv, CvSubstEnv)
  tyCoVarsOf   :: t -> TyCoVarSet
  tyCoVarsOf_s :: [t] -> TyCoVarSet

instance Unifiable Type where
  match = match_ty
  unify = unify_ty
  tyCoVarsOf = tyCoVarsOfType
  tyCoVarsOf_s = tyCoVarsOfTypes

instance Unifiable Coercion where
  match = match_co
  unify = unify_co
  tyCoVarsOf = tyCoVarsOfCo
  tyCoVarsOf_s = tyCoVarsOfCos

instance Unifiable CoercionArg where
  match = match_co_arg
  unify = unify_co_arg
  tyCoVarsOf = tyCoVarsOfCoArg
  tyCoVarsOf_s = tyCoVarsOfCoArgs

data MatchEnv
  = ME	{ me_tmpls :: VarSet	-- Template variables
 	, me_env   :: RnEnv2	-- Renaming envt for nested foralls
	}			--   In-scope set includes template variables
    -- Nota Bene: MatchEnv isn't specific to Types.  It is used
    --            for matching terms and coercions as well as types

tcMatch :: Unifiable t
        => TyCoVarSet	  -- Template tyvars
        -> t		  -- Template
        -> t              -- Target
        -> Maybe TCvSubst -- One-shot; in principle the template
			  -- variables could be free in the target

tcMatch tmpls ty1 ty2
  = case match menv emptyTvSubstEnv emptyCvSubstEnv ty1 ty2 of
	Just (tv_env, cv_env) -> Just (TCvSubst in_scope tv_env cv_env)
	Nothing	              -> Nothing
  where
    menv     = ME { me_tmpls = tmpls, me_env = mkRnEnv2 in_scope }
    in_scope = mkInScopeSet (tmpls `unionVarSet` tyCoVarsOf ty2)
	-- We're assuming that all the interesting 
	-- tyvars in tys1 are in tmpls

tcMatchTy :: TyCoVarSet -> Type -> Type -> Maybe TCvSubst
tcMatchTy = tcMatch

tcMatchCo :: TyCoVarSet -> Coercion -> Coercion -> Maybe TCvSubst
tcMatchCo = tcMatch

tcMatches :: Unifiable t
          => TyCoVarSet	    -- Template tyvars
	  -> [t]	    -- Template
	  -> [t]	    -- Target
	  -> Maybe TCvSubst -- One-shot; in principle the template
			    -- variables could be free in the target

tcMatches tmpls tys1 tys2
  = case match_list menv emptyTvSubstEnv emptyCvSubstEnv tys1 tys2 of
	Just (tv_env, cv_env) -> Just (TCvSubst in_scope tv_env cv_env)
	Nothing	              -> Nothing
  where
    menv     = ME { me_tmpls = tmpls, me_env = mkRnEnv2 in_scope }
    in_scope = mkInScopeSet (tmpls `unionVarSet` tyCoVarsOf_s tys2)
	-- We're assuming that all the interesting 
	-- tyvars in tys1 are in tmpls

tcMatchTys :: TyCoVarSet -> [Type] -> [Type] -> Maybe TCvSubst
tcMatchTys = tcMatches

tcMatchCos :: TyCoVarSet -> [Coercion] -> [Coercion] -> Maybe TCvSubst
tcMatchCos = tcMatches

-- This is similar, but extends a substitution
tcMatchX :: Unifiable t
         => TyCoVarSet 	        -- Template tyvars
         -> TCvSubst		-- Substitution to extend
         -> t          		-- Template
         -> t	        	-- Target
         -> Maybe TCvSubst
tcMatchX tmpls (TCvSubst in_scope tv_env cv_env) ty1 ty2
  = case match menv tv_env cv_env ty1 ty2 of
	Just (tv_env, cv_env) -> Just (TCvSubst in_scope tv_env cv_env)
	Nothing	              -> Nothing
  where
    menv = ME {me_tmpls = tmpls, me_env = mkRnEnv2 in_scope}

tcMatchTyX :: TyCoVarSet -> TCvSubst -> Type -> Type -> Maybe TCvSubst
tcMatchTyX = tcMatchX

tcMatchCoX :: TyCoVarSet -> TCvSubst -> Coercion -> Coercion -> Maybe TCvSubst
tcMatchCoX = tcMatchX

tcMatchPreds
	:: [TyVar]			-- Bind these
	-> [PredType] -> [PredType]
   	-> Maybe (TvSubstEnv, CvSubstEnv)
tcMatchPreds tmpls ps1 ps2
  = match_list menv emptyTvSubstEnv emptyCvSubstEnv ps1 ps2
  where
    menv = ME { me_tmpls = mkVarSet tmpls, me_env = mkRnEnv2 in_scope_tyvars }
    in_scope_tyvars = mkInScopeSet (tyCoVarsOfTypes ps1 `unionVarSet` tyCoVarsOfTypes ps2)

-- This one is called from the expression matcher, which already has a MatchEnv in hand
ruleMatchTyX :: MatchEnv 
	 -> TvSubstEnv		-- type substitution to extend
         -> CvSubstEnv          -- coercion substitution to extend
	 -> Type		-- Template
	 -> Type		-- Target
	 -> Maybe (TvSubstEnv, CvSubstEnv)
ruleMatchTyX = match

ruleMatchCoX :: MatchEnv -> TvSubstEnv -> CvSubstEnv
             -> Type -> Type -> Maybe (TvSubstEnv, CvSubstEnv)
ruleMatchCoX = match

-- Rename for export
\end{code}

Now the internals of matching

\begin{code}
match_ty :: MatchEnv	-- For the most part this is pushed downwards
      -> TvSubstEnv 	-- Substitution so far:
			--   Domain is subset of template tyvars
			--   Free vars of range is subset of 
			--	in-scope set of the RnEnv2
      -> CvSubstEnv
      -> Type -> Type	-- Template and target respectively
      -> Maybe TvSubstEnv

match_ty menv tsubst csubst ty1 ty2
  | Just ty1' <- coreView ty1 = match_ty menv tsubst csubst ty1' ty2
  | Just ty2' <- coreView ty2 = match_ty menv tsubst csubst ty1 ty2'

match_ty menv tsubst csubst (TyVarTy tv1) ty2
  | Just ty1' <- lookupVarEnv tsubst tv1'	-- tv1' is already bound
  = if eqTypeX (nukeRnEnvL rn_env) ty1' ty2
	-- ty1 has no locally-bound variables, hence nukeRnEnvL
    then Just (tsubst, csubst)
    else Nothing	-- ty2 doesn't match

  | tv1' `elemVarSet` me_tmpls menv
  = if any (inRnEnvR rn_env) (varSetElems (tyCoVarsOfType ty2))
    then Nothing	-- Occurs check
    else do { (tsubst1, csubst1)
                <- match_kind menv tsubst csubst (tyVarKind tv1') (typeKind ty2)
	    ; return (extendVarEnv tsubst1 tv1' ty2, csubst1) }

   | otherwise	-- tv1 is not a template tyvar
   = case ty2 of
	TyVarTy tv2 | tv1' == rnOccR rn_env tv2 -> Just (tsubst, csubst)
	_                                       -> Nothing
  where
    rn_env = me_env menv
    tv1' = rnOccL rn_env tv1

match_ty menv tsubst csubst (ForAllTy tv1 ty1) (ForAllTy tv2 ty2) 
  = do { (tsubst', csubst') <- match_kind menv tsubst csubst (tyVarKind tv1) (tyVarKind tv2)
       ; match_ty menv' tsubst' csubst' ty1 ty2 }
  where		-- Use the magic of rnBndr2 to go under the binders
    menv' = menv { me_env = rnBndr2 (me_env menv) tv1 tv2 }

match_ty menv tsubst csubst (TyConApp tc1 tys1) (TyConApp tc2 tys2) 
  | tc1 == tc2 = match_list menv tsubst csubst tys1 tys2
match_ty menv tsubst csubst (FunTy ty1a ty1b) (FunTy ty2a ty2b) 
  = do { (tsubst', csubst') <- match_ty menv tsubst csubst ty1a ty2a
       ; match_ty menv tsubst' csubst' ty1b ty2b }
match_ty menv tsubst csubst (AppTy ty1a ty1b) ty2
  | Just (ty2a, ty2b) <- repSplitAppTy_maybe ty2
	-- 'repSplit' used because the tcView stuff is done above
  = do { (tsubst', csubst') <- match_ty menv tsubst csubst ty1a ty2a
       ; match_ty menv tsubst' csubst' ty1b ty2b }

match_ty _ tsubst csubst (LitTy x) (LitTy y) | x == y  = return (tsubst, csubst)

match_ty menv tsubst csubst (CastTy ty1 co1) (CastTy ty2 co2)
  = do { (tsubst', csubst') <- match_ty menv tsubst csubst ty1 ty2
       ; match_co menv tsubst csubst co1 co2 }

match_ty menv tsubst csubst (CoercionTy co1) (CoercionTy co2)
  = match_co menv tsubst csubst co1 co2

match_ty _ _ _ _ _
  = Nothing

--------------
match_kind :: MatchEnv -> TvSubstEnv -> Kind -> Kind -> Maybe TvSubstEnv
-- Match the kind of the template tyvar with the kind of Type
match_kind menv subst k1 k2
  | k2 `isSubKind` k1
  = return subst

  | otherwise
  = match menv subst k1 k2

\end{code}

Note [Unifying with Refl]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Because of Refl invariant #2 (see Note [Refl invariant]), any reflexive
coercion must be constructed with Refl. This means that any of the smart
constructors for Coercions check for reflexivity and produce Refl in that
case. Because the substitution operation uses these smart constructors, *any*
coercion might become Refl after substitution. So, when matching, we must
allow for this possibility. We do so by, when the target coercion is a Refl,
trying to match the kind of the coercion with the kind of the Refl. If these
match, then the substitution produced will indeed make the substituted
coercion become Refl, as desired.

But, what to do when a CoVarCo is matched with a Refl? There are two ways a
CoVarCo can become a Refl under substitution: the underlying CoVar can be
mapped to a Refl coercion; or the types of the CoVar can end up becoming the
same, triggering the Refl invariant. This matching algorithm therefore has a
choice. If a CoVarCo is matched with a Refl, do we make a mapping from the
CoVar, or do we just unify the kinds? This choice is apparent in the ordering
of the first two clauses of match_co below. It seems that taking the second
option -- just unifying the kinds -- means strictly less work, so that is the
route I have taken. This means that the final substitution will not contain a
mapping for the CoVar in question, but that should be OK.

Note [Coercion optimizations and match_co]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The algorithm in match_co must be kept carefully in sync with the
optimizations and simplifications done in the smart constructors of coercions.
We want this property: if Just subst = match co1 co2, then subst(co1) = co2.
And, we want this one: if Nothing = match co1 co2, then there exists no such
possible substitution. Because substitution uses the smart constructors,
we must account for the possibility that the structure of a coercion changes
during substitution. This isn't that hard to do, but we still must be careful
about it. For example, mkUnsafeCo sometimes produces a TyConAppCo, *not* an
UnsafeCo. So, we must allow for the possibility that an UnsafeCo will become
a TyConAppCo after substitution, and check for this case in matching.

\begin{code}

--------------
-- See Note [Coercion optimizations and match_co]
match_co :: MatchEnv -> TvSubstEnv -> CvSubstEnv
         -> Coercion -> Coercion -> Maybe (TvSubstEnv, CvSubstEnv)

-- See Note [Unifying with Refl]
-- any coercion shape can become a refl under certain conditions:
match_co menv tsubst csubst co1 (Refl ty2)
  = do { let Pair tyl1 tyr1 = coercionKind co1
       ; (tsubst', csubst') <- match_ty menv tsubst csubst tyl1 ty2
       ; match_ty menv tsubst' csubst' tyr1 ty2 }

-- See Note [Unifying with Refl]
match_co menv tsubst csubst (CoVarCo cv1) co2
  | Just co1' <- lookupVarEnv csubst cv1'   -- cv1' is already bound
  = if eqCoercionX (nukeRnEnvL rn_env) co1' co2
          -- co1' has no locally-bound variables, hence nukeRnEnvL
    then Just (tsubst, csubst)
    else Nothing -- co2 doesn't match

  | tv1' `elemVarSet` me_tmpls menv
  = if any (inRnEnvR rn_env) (varSetElems (tyCoVarsOfCo co2))
    then Nothing -- occurs check
    else do { (tsubst1, csubst1) <- match_ty menv tsubst csubst (coVarKind cv1')
                                                                (coercionType co2)
            ; return (tsubst1, extendVarEnv csubst1 cv1' co2)

  | otherwise -- cv1 is not a template covar
  = case co2 of
      CoVarCo cv2 | cv1' == rnOccR rn_env tv2 -> Just (tsubst, csubst)
      _                                       -> Nothing
  where
    rn_env = me_env menv
    cv1' = rnOccL rn_env cv1

-- Refl case already handled:
match_co menv tsubst csubst (TyConAppCo tc1 args1) (TyConAppCo tc2 args2)
  | tc1 == tc2 = match_list menv tsubst csubst args1 args2

match_co menv tsubst csubst (AppCo co1 arg1) co2
  | Just (co2, arg2) <- splitAppCo_maybe
  = do { (tsubst', csubst') <- match_co menv tsubst csubst co1 co2
       ; match_co_arg menv tsubst' csubst' arg1 arg2 }

match_co menv tsubst csubst (ForAllCo cobndr1 co1) (ForAllCo cobndr2 co2)
  | TyHomo tv1 <- cobndr1
  , TyHomo tv2 <- cobndr2
  = do { (tsubst', csubst') <- match_kind menv tsubst csubst (tyVarKind tv1)
                                                             (tyVarKind tv2)
       ; let menv' = menv { me_env = rnBndr2 (me_env menv) tv1 tv2 }
       ; match_co menv' tsubst' csubst' co1 co2 }
  
  | TyHetero eta1 tvl1 tvr1 cv1 <- cobndr1
  , TyHomo tv2
  = do { (tsubst1, csubst1) <- match_co menv tsubst csubst 
                                        eta1 (mkReflCo (tyVarKind tv2))
       ; (tsubst2, csubst2) <- match_kind menv tsubst1 csubst1 (tyVarKind tvl1)
                                                               (tyVarKind tvr1)
       ; let rn_env = me_env menv
             in_scope = rnInScopeSet rn_env
             homogenized = substCoWithIS in_scope
                                         [tvr1,               cv1]
                                         [mkOnlyTyVarTy tvl1, mkReflCo (mkOnlyTyVarTy tvl1)]
                                         co1
             menv' = menv { me_env = rnBndr2 rn_env tvl1 tv2 }
       ; match_co menv' tsubst2 csubst2 homogenized co2 }

  | TyHetero eta1 tvl1 tvr1 cv1 <- cobndr1
  , TyHetero eta2 tvl2 tvr2 cv2 <- cobndr2
  = do { (tsubst1, csubst1) <- match_co menv tsubst csubst eta1 eta2
       ; (tsubst2, csubst2) <- match_kind menv tsubst1 csubst1 (tyVarKind tvl1)
                                                               (tyVarKind tvl2)
       ; (tsubst3, csubst3) <- match_kind menv tsubst2 csubst2 (tyVarKind tvr1)
                                                               (tyVarKind tvr2)
       ; let menv' = menv { me_env = rnBndrs2 (me_env menv) [tvl1, tvr1, cv1]
                                                            [tvl2, tvr2, cv2] }
       ; match_co menv' tsubst3 csubst3 co1 co2 }

  | CoHomo cv1 <- cobndr1
  , CoHomo cv2 <- cobndr2
  = do { (tsubst', csubst') <- match_ty menv tsubst csubst (coVarKind cv1)
                                                           (coVarKind cv2)
       ; let menv' = menv { me_env = rnBndr2 (me_env menv) cv1 cv2 }
       ; match_co menv' tsubst' csubst' co1 co2 }

  | CoHetero eta1 cvl1 cvr1 <- cobndr1
  , CoHomo cv2
  = do { (tsubst1, csubst1) <- match_co menv tsubst csubst
                                        eta1 (mkReflCo (coVarKind cv2))
       ; (tsubst2, csubst2) <- match_ty menv tsubst1 csubst1 (coVarKind cvl1)
                                                             (coVarKind cvr1)
       ; let rn_env = me_env menv
             in_scape = rnInScopeSet rn_env
             homogenized = substCoWithIS in_scope
                                         [cvr1] [mkCoercionTy $ mkCoVarCo cvl1] co1
             menv' = menv { me_env = rnBndr2 rn_env cvl1 cv2 }
       ; match_co menv' tsubst2 csubst2 homogenized co2 }

  | CoHetero eta1 cvl1 cvr1 <- cobndr1
  , CoHetero eta2 cvl2 cvr2 <- cobndr2
  = do { (tsubst1, csubst1) <- match_co menv tsubst csubst eta1 eta2
       ; (tsubst2, csubst2) <- match_ty menv tsubst1 csubst1 (coVarKind cvl1)
                                                             (coVarKind cvl2)
       ; (tsubst3, csubst3) <- match_ty menv tsubst2 csubst2 (coVarKind cvr1)
                                                             (coVarKind cvr2)
       ; let menv' = menv { me_env = rnBndrs2 (me_env menv) [cvl1, cvr1]
                                                            [cvl2, cvr2] }
       ; match_co menv' tsubst3 csubst3 co1 co2 }

  -- TyHomo can't match with TyHetero, and same for Co

match_co menv tsubst csubst (AxiomInstCo ax1 ind1 args1)
                            (AxiomInstCo ax2 ind2 args2)
  | ax1 == ax2
  , ind1 == ind2
  = match_list menv tsubst csubst args1 args2

match_co menv tsubst csubst (UnsafeCo tyl1 tyr1) (UnsafeCo tyl2 tyr2)
  = do { (tsubst', csubst') <- match_ty menv tsubst csubst tyl1 tyl2
       ; match_ty menv tsubst' csubst' tyr1 tyr2 }
match_co menv tsubst csubst (UnsafeCo lty1 rty1) co2@(TyConAppCo _ _)
  = do { let Pair lty2 rty2 = coercionKind co2
       ; (tsubst', csubst') <- match_ty menv tsubst csubst lty1 lty2
       ; match_ty menv tsubst' csubst' rty1 rty2 }

-- it's safe to do these in order because there is never a SymCo (SymCo ...)
-- or a SymCo (UnsafeCo ...)
match_co menv tsubst csubst (SymCo co1) (SymCo co2)
  = match_co menv tsubst csubst co1 co2
match_co menv tsubst csubst (SymCo co1) (UnsafeCo lty2 rty2)
  = match_co menv tsubst csubst co1 (UnsafeCo rty2 lty2)
match_co menv tsubst csubst (SymCo co1) co2
  = match_co menv tsubst csubst co1 (SymCo co2)

match_co menv tsubst csubst (TransCo col1 cor1) (TransCo col2 cor2)
  = do { (tsubst', csubst') <- match_co menv tsubst csubst col1 col2
       ; match_co menv tsubst' csubst' cor1 cor2 } ]

match_co menv tsubst csubst (NthCo n1 co1) (NthCo n2 co2)
  | n1 == n2
  = match_co menv tsubst csubst co1 co2

match_co menv tsubst csubst (LRCo lr1 co1) (LRCo lr2 co2)
  | lr1 == lr2
  = match_co menv tsubst csubst co1 co2

match_co menv tsubst csubst (InstCo co1 arg1) (InstCo co2 arg2)
  = do { (tsubst', csubst') <- match_co menv tsubst csubst co1 co2
       ; match_co_arg menv tsubst' csubst' arg1 arg2 }

match_co menv tsubst csubst (CoherenceCo lco1 rco1) (CoherenceCo lco2 rco2)
  = do { (tsubst', csubst') <- match_co menv tsubst csubst lco1 lco2
       ; match_co menv tsubst' csubst' rco1 rco2 } ]

match_co menv tsubst csubst (KindCo co1) (KindCo co2)
  = match_co menv tsubst csubst co1 co2

match_co _ _ _ _ _
  = Nothing


match_co_arg :: MatchEnv -> TvSubstEnv -> CvSubstEnv
             -> CoercionArg -> CoercionArg -> Maybe (TvSubstEnv, CvSubstEnv)
match_co_arg menv tsubst csubst (TyCoArg co1) (TyCoArg co2)
  = match_co menv tsubst csubst co1 co2
match_co_arg menv tsubst csubst (CoCoArg lco1 rco1) (CoCoArg lco2 rco2)
  = do { (tsubst', csubst') <- match_co menv tsubst csubst lco1 lco2
       ; match_co menv tsubst' csubst' rco1 rco2 }

-------------

match_list :: Unifiable t => MatchEnv ->
              TvSubstEnv -> CvSubstEnv -> [t] -> [t] -> Maybe (TvSubstEnv, CvSubstEnv)
match_list fn menv tenv cenv = matchList (\(tenv, cenv) -> fn menv tenv cenv) (tenv, cenv)

matchList :: (env -> a -> b -> Maybe env)
	   -> env -> [a] -> [b] -> Maybe env
matchList _  subst []     []     = Just subst
matchList fn subst (a:as) (b:bs) = do { subst' <- fn subst a b
				      ; matchList fn subst' as bs }
matchList _  _     _      _      = Nothing
\end{code}

%************************************************************************
%*									*
	Matching monad
%*									*
%************************************************************************

\begin{code}

newtype MatchM a = MM { unMM :: MatchEnv -> TvSubstEnv -> CvSubstEnv
                             -> Maybe ((TvSubstEnv, CvSubstEnv), a) }

instance Monad MatchMM where
  return x = MM $ \menv tsubst csubst -> Just ((tsubst, csubst), x)
  fail _   = MM $ \_ _ _ -> Nothing

  (a >>= f) = MM $ \menv tsubst csubst -> case unMM a menv tsubst csubst of
    Just ((tsubst', csubst'), a') -> unMM (f a') menv tsubst' csubst'
    Nothing                       -> Nothing

runMatchM :: MatchM a -> MatchEnv -> TvSubstEnv -> CvSubstEnv
          -> Maybe (TvSubstEnv, CvSubstEnv)
runMatchMM mm menv tsubst csubst
  -- in the Maybe monad
  = do { ((tsubst', csubst'), _) <- unMM mm menv tsubst csubst
       ; return (tsubst', csubst') }

getRnEnv :: MatchM RnEnv2
getRnEnv = MM $ \menv tsubst csubst -> Just ((tsubst, csubst), me_env menv)

withRnEnv :: RnEnv2 -> MatchM a -> MatchM a
withRnEnv rn_env mm = MM $ \menv tsubst csubst
                           -> unMM mm (menv { me_env = rn_env }) tsubst csubst

\end{code}

%************************************************************************
%*									*
		GADTs
%*									*
%************************************************************************

Note [Pruning dead case alternatives]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider	data T a where
		   T1 :: T Int
		   T2 :: T a

		newtype X = MkX Int
		newtype Y = MkY Char

		type family F a
		type instance F Bool = Int

Now consider	case x of { T1 -> e1; T2 -> e2 }

The question before the house is this: if I know something about the type
of x, can I prune away the T1 alternative?

Suppose x::T Char.  It's impossible to construct a (T Char) using T1, 
	Answer = YES we can prune the T1 branch (clearly)

Suppose x::T (F a), where 'a' is in scope.  Then 'a' might be instantiated
to 'Bool', in which case x::T Int, so
	ANSWER = NO (clearly)

Suppose x::T X.  Then *in Haskell* it's impossible to construct a (non-bottom) 
value of type (T X) using T1.  But *in FC* it's quite possible.  The newtype
gives a coercion
	CoX :: X ~ Int
So (T CoX) :: T X ~ T Int; hence (T1 `cast` sym (T CoX)) is a non-bottom value
of type (T X) constructed with T1.  Hence
	ANSWER = NO we can't prune the T1 branch (surprisingly)

Furthermore, this can even happen; see Trac #1251.  GHC's newtype-deriving
mechanism uses a cast, just as above, to move from one dictionary to another,
in effect giving the programmer access to CoX.

Finally, suppose x::T Y.  Then *even in FC* we can't construct a
non-bottom value of type (T Y) using T1.  That's because we can get
from Y to Char, but not to Int.


Here's a related question.  	data Eq a b where EQ :: Eq a a
Consider
	case x of { EQ -> ... }

Suppose x::Eq Int Char.  Is the alternative dead?  Clearly yes.

What about x::Eq Int a, in a context where we have evidence that a~Char.
Then again the alternative is dead.   


			Summary

We are really doing a test for unsatisfiability of the type
constraints implied by the match. And that is clearly, in general, a
hard thing to do.  

However, since we are simply dropping dead code, a conservative test
suffices.  There is a continuum of tests, ranging from easy to hard, that
drop more and more dead code.

For now we implement a very simple test: type variables match
anything, type functions (incl newtypes) match anything, and only
distinct data types fail to match.  We can elaborate later.

\begin{code}
typesCantMatch :: [(Type,Type)] -> Bool
typesCantMatch prs = any (\(s,t) -> cant_match s t) prs
  where
    cant_match :: Type -> Type -> Bool
    cant_match t1 t2
	| Just t1' <- coreView t1 = cant_match t1' t2
	| Just t2' <- coreView t2 = cant_match t1 t2'

    cant_match (FunTy a1 r1) (FunTy a2 r2)
	= cant_match a1 a2 || cant_match r1 r2

    cant_match (TyConApp tc1 tys1) (TyConApp tc2 tys2)
	| isDistinctTyCon tc1 && isDistinctTyCon tc2
	= tc1 /= tc2 || typesCantMatch (zipEqual "typesCantMatch" tys1 tys2)

    cant_match (FunTy {}) (TyConApp tc _) = isDistinctTyCon tc
    cant_match (TyConApp tc _) (FunTy {}) = isDistinctTyCon tc
	-- tc can't be FunTyCon by invariant

    cant_match (AppTy f1 a1) ty2
	| Just (f2, a2) <- repSplitAppTy_maybe ty2
	= cant_match f1 f2 || cant_match a1 a2
    cant_match ty1 (AppTy f2 a2)
	| Just (f1, a1) <- repSplitAppTy_maybe ty1
	= cant_match f1 f2 || cant_match a1 a2

    cant_match (LitTy x) (LitTy y) = x /= y

    cant_match _ _ = False      -- Safe!

-- Things we could add;
--	foralls
--	look through newtypes
--	take account of tyvar bindings (EQ example above)
\end{code}


%************************************************************************
%*									*
             Unification
%*                                                                      *
%************************************************************************

Note [Unification and apartness]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The workhorse function behind unification actually is testing for apartness,
not unification. Here, two types are apart if it is never possible to unify
them or any types they are safely coercible to.(* see below) There are three
possibilities here:

 - two types might be NotApart, which means a substitution can be found between
   them,

   Example: (Either a Int) and (Either Bool b) are NotApart, with
   [a |-> Bool, b |-> Int]

 - they might be MaybeApart, which means that we're not sure, but a substitution
   cannot be found

   Example: Int and F a (for some type family F) are MaybeApart

 - they might be SurelyApart, in which case we can guarantee that they never
   unify

   Example: (Either Int a) and (Either Bool b) are SurelyApart

In the NotApart case, the apartness finding function also returns a
substitution, which we can then use to unify the types. It is necessary for
the unification algorithm to depend on the apartness algorithm, because
apartness is finer-grained than unification.

Note [Unifying with type families]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
We wish to separate out the case where unification fails on a type family
from other unification failure. What does "fail on a type family" look like?
According to the TyConApp invariant, a type family application must always
be in a TyConApp. This TyConApp may not be buried within the left-hand-side
of an AppTy.

Furthermore, we wish to proceed with unification if we are unifying
(F a b) with (F Int Bool). Here, unification should succeed with
[a |-> Int, b |-> Bool]. So, here is what we do:

 - If we are unifying two TyConApps, check the heads for equality and
   proceed iff they are equal.

 - Otherwise, if either (or both) type is a TyConApp headed by a type family,
   we know they cannot fully unify. But, they might unify later, depending
   on the type family. So, we return "maybeApart".

Note that we never want to unify, say, (a Int) with (F Int), because doing so
leads to an unsaturated type family. So, we don't have to worry about any
unification between type families and AppTys.

But wait! There is one more possibility. What about nullary type families?
If G is a nullary type family, we *do* want to unify (a) with (G). This is
handled in uVar, which is triggered before we look at TyConApps. Ah. All is
well again.

Note [Apartness with skolems]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
If we discover that two types unify if and only if a skolem variable is
substituted, we can't properly unify the types. But, that skolem variable
may later be instantiated with a unifyable type. So, we return maybeApart
in these cases.

Note [Apartness and coercions]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
What does it mean for two coercions to be apart? It has to mean that the
types coerced between are apart. In cannot mean that there is no unification
from one coercion to another. The problem is that, in general, there are
many shapes a coercion might take. Any two coercions that coerce between
the same two types are fully equivalent. Even with wildly different
structures, it would be folly to say that they are "apart". So, a failure
to unify two coercions can yield surelyApart if and only if the types
coerced between are surelyApart. Otherwise, two coercions either unify or
are maybeApart.

\begin{code}
-- See Note [Unification and apartness]
tcUnifyTys :: (TyCoVar -> BindFlag)
	   -> [Type] -> [Type]
	   -> Maybe TCvSubst	-- A regular one-shot (idempotent) substitution
-- The two types may have common type variables, and indeed do so in the
-- second call to tcUnifyTys in FunDeps.checkClsFD
--
tcUnifyTys bind_fn tys1 tys2
  | NotApart subst <- tcApartTys bind_fn tys1 tys2
  = Just subst
  | otherwise
  = Nothing

data ApartResult = NotApart TCvSubst   -- the subst that unifies the types
                 | MaybeApart
                 | SurelyApart

tcApartTys :: (TyCoVar -> BindFlag)
           -> [Type] -> [Type]
           -> ApartResult
tcApartTys bind_fn tys1 tys2
  = initUM bind_fn $
    do { (tsubst, csubst) <- unifyList emptyTvSubstEnv emptyCvSubstEnv tys1 tys2

	-- Find the fixed point of the resulting non-idempotent substitution
        ; return (niFixTCvSubst tsubst csubst) }
\end{code}


%************************************************************************
%*									*
                Non-idempotent substitution
%*									*
%************************************************************************

Note [Non-idempotent substitution]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
During unification we use a TvSubstEnv/CvSubstEnv pair that is
  (a) non-idempotent
  (b) loop-free; ie repeatedly applying it yields a fixed point

\begin{code}
niFixTvSubst :: TvSubstEnv -> CvSubstEnv -> TCvSubst
-- Find the idempotent fixed point of the non-idempotent substitution
-- ToDo: use laziness instead of iteration?
niFixTvSubst tenv cenv = f tenv cenv
  where
    f tenv cenv
        | not_fixpoint = f (mapVarEnv (substTy subst) tenv)
                           (mapVarEnv (substCo subst) cenv)
        | otherwise    = subst
        where
          range_tvs    = foldVarEnv (unionVarSet . tyCoVarsOfType) emptyVarSet tenv
          range_cvs    = foldVarEnv (unionVarSet . tyCoVarsOfCo) emptyVarSet cenv
          range        = range_tvs `unionVarSet` range_cvs
          in_scope     = mkInScopeSet range
          subst        = mkTCvSubst in_scope tenv cenv
                         
          not_fixpoint = foldVarSet ((||) . in_domain) False range
          in_domain tv = tv `elemVarEnv` tenv || tv `elemVarEnv` cenv

niSubstTvSet :: TvSubstEnv -> CvSubstEnv -> TyCoVarSet -> TyCoVarSet
-- Apply the non-idempotent substitution to a set of type variables,
-- remembering that the substitution isn't necessarily idempotent
-- This is used in the occurs check, before extending the substitution
niSubstTvSet tsubst csubst tvs
  = foldVarSet (unionVarSet . get) emptyVarSet tvs
  where
    get tv
      | isTyVar tv
      = case lookupVarEnv tsubst tv of
	       Nothing -> unitVarSet tv
               Just ty -> niSubstTvSet tsubst csubst (tyCoVarsOfType ty)
      | otherwise
      = case lookupVarEnv csubst tv of
               Nothing -> unitVarSet tv
               Just co -> niSubstTvSet tsubst csubst (tyCoVarsOfCo co)
\end{code}

%************************************************************************
%*									*
		The workhorse
%*									*
%************************************************************************

Note [unify_co SymCo case]
~~~~~~~~~~~~~~~~~~~~~~~~~~
mkSymCo says that mkSymCo (SymCo co) = co. So, it is, in general, possible
for a SymCo to unify with any other coercion. For example, if we have
(SymCo c) (for a coercion variable c), that unifies with any coercion co
with [c |-> SymCo co]. Now, consider a unification problem: we wish to unify
(SymCo co1) with co2. If co2 is not a SymCo or an UnsafeCo (the two other
possible outcomes of mkSymCo) then we should try to unify co1 with (SymCo co2).
The problem is that, if that also fails, a naive algorithm would then try
pushing the SymCo back onto co1. What we need is to make sure we swap the SymCo
only once, prevent infinite recursion. This is done in unify_co_sym with the
SymFlag parameter.

\begin{code}
unify_ty :: Type -> Type   -- Types to be unified
         -> UM ()
-- We do not require the incoming substitution to be idempotent,
-- nor guarantee that the outgoing one is.  That's fixed up by
-- the wrappers.

-- Respects newtypes, PredTypes

-- in unify, any NewTcApps/Preds should be taken at face value
unify_ty (TyVarTy tv1) ty2  = uVar tv1 ty2
unify_ty ty1 (TyVarTy tv2)  = umSwapRn $ uVar tv2 ty1

unify_ty ty1 ty2
  | Just ty1' <- tcView ty1 = unify_ty ty1' ty2
  | Just ty2' <- tcView ty2 = unify_ty ty1 ty2'

unify_ty (TyConApp tyc1 tys1) (TyConApp tyc2 tys2)
  | tyc1 == tyc2                                   
  = unify_tys tys1 tys2

-- See Note [Unifying with type families]
unify_ty (TyConApp tyc _) _
  | not (isDistinctTyCon tyc) = maybeApart
unify_ty _ (TyConApp tyc _)
  | not (isDistinctTyCon tyc) = maybeApart

unify_ty (FunTy ty1a ty1b) (FunTy ty2a ty2b) 
  = do	{ unify_ty ty1a ty2a
	; unify_ty ty1b ty2b }

	-- Applications need a bit of care!
	-- They can match FunTy and TyConApp, so use splitAppTy_maybe
	-- NB: we've already dealt with type variables and Notes,
	-- so if one type is an App the other one jolly well better be too
unify_ty (AppTy ty1a ty1b) ty2
  | Just (ty2a, ty2b) <- repSplitAppTy_maybe ty2
  = do	{ unify_ty ty1a ty2a
        ; unify_ty ty1b ty2b }

unify_ty ty1 (AppTy ty2a ty2b)
  | Just (ty1a, ty1b) <- repSplitAppTy_maybe ty1
  = do	{ unify_ty ty1a ty2a
        ; unify_ty ty1b ty2b }

unify_ty (LitTy x) (LitTy y) | x == y = return ()

unify_ty (ForAllTy tv1 ty1) (ForAllty tv2 ty2)
  = do { unify_ty (tyVarKind tv1) (tyVarKind tv2)
       ; umRnBndr2 tv1 tv2 $ unify_ty ty1 ty2 }

unify_ty _ _ = surelyApart

unify_tys :: [Type] -> [Type] -> UM ()
unify_tys = unifyList

-----------------------------------------
unify_co :: Coercion -> Coercion -> UM ()
-- See Note [Coercion optimizations and match_co]. It applies here too.
-- See Note [Apartness and coercions]
unify_co co1 co2
  = do { let Pair tyl1 tyr1 = coercionKind co1
             Pair tyl2 tyr2 = coercionKind co2
       ; unify_ty tyl1 tyl2
       ; unify_ty tyr1 tyr2
       ; dontBeSoSure $ unify_co' co1 co2 }

-- Unify two Coercions with unified kinds
unify_co' :: Coercion -> Coercion -> UM ()

-- in the Refl case, the kinds are already unified, so there is no more work.
-- See Note [Unifying with Refl]
unify_co' (Refl _) _ = return ()
unify_co' _ (Refl _) = return ()

unify_co' (CoVarCo cv1) co2 = uVar cv1 co2
unify_co' co1 (CoVarCo cv2) = umSwapRn $ uVar cv2 co1

unify_co' (TyConAppCo tc1 args1) (TyConAppCo tc2 args2)
 | tc1 == tc2 = unifyList args1 args2

unify_co' g1@(ForAllCo cobndr1 co1) g2@(ForAllCo cobndr2 co2)
 | Just v1 <- getHomoVar_maybe cobndr1
 , Just v2 <- getHomoVar_maybe cobndr2
 = do { unify_ty (varType v1) (varType v2)
      ; umRnBndr2 v1 v2 $ unify_co co1 co2 }

 | Just (eta1, lv1, rv1) <- splitHeteroCoBndr_maybe cobndr1
 , Just (eta2, lv2, rv2) <- splitHeteroCoBndr_maybe cobndr2
 = do { unify_co eta1 eta2
      ; unify_ty (varType lv1) (varType lv2)
      ; unify_ty (varType rv1) (varType rv2)
      ; let rnCoVar :: UM a -> UM a
            rnCoVar
              = case cobndr1 of
                { TyHetero _ _ _ cv1 -> case cobndr2 of
                  { TyHetero _ _ _ cv2 -> umRnBndr2 cv1 cv2
                  ; _                  -> \_ -> maybeApart } -- one is Ty, one is Co
                ; _                  -> id }
      ; umRnBndr2 lv1 lv2 $
        umRnBndr2 rv1 rv2 $
        rnCoVar $
        unify_co co1 co2 }

  -- mixed Homo/Hetero case. Ugh. Only handle where 1 is hetero and 2 is homo;
  -- otherwise, flip 1 and 2
  | Just _ <- getHomoVar_maybe cobndr1
  | Just _ <- splitHeteroCoBndr_maybe cobndr2
  = umSwapRn $ unify_co' g2 g1

  | Just (eta1, lv1, rv1) <- splitHeteroCoBndr_maybe cobndr1
  , Just v2               <- getHomoVar_maybe cobndr2
  = do { unify_co eta1 (mkReflCo (varType v2))
       ; unify_ty (varType lv1) (varType rv1)
       ; homogenize $ \co1' ->
         umRnBndr2 lv1 v2 $
         unify_co co1' co2 }
  where
    homogenize :: (Coercion -> UM a) -> UM a
    homogenize thing
      = do { in_scope <- getInScope
           ; let co1' = case cobndr1 of
                        { TyHetero _ ltv1 rtv1 cv1
                            -> let lty = mkOnlyTyVarTy ltv1 in
                               substCoWithIS in_scope [rtv1, cv1]
                                                      [lty,  mkReflCo lty] co1
                        ; CoHetero _ lcv1 rcv1
                            -> let lco = mkCoVarCo lcv1 in
                               substCoWithIS in_scope [rcv1] [mkCoercionTy lco] co1
                        ; _ -> pprPanic "unify_co'#homogenize" (ppr g1) }
           ; thing co1' }

unify_co' (AxiomInstCo ax1 ind1 args1) (AxiomInstCo ax2 ind2 args2)
  | ax1 == ax2
  , ind1 == ind2
  = unify_list args1 args2

unify_co' (UnsafeCo tyl1 tyr1) (UnsafeCo tyl2 tyr2)
  = do { unify_ty tyl1 tyl2
       ; unify_ty tyr1 tyr2 }
unify_co' (UnsafeCo lty1 rty1) co2@(TyConAppCo _ _)
  = do { let Pair lty2 rty2 = coercionKind co2
       ; unify_ty lty1 lty2
       ; unify_ty rty1 rty2 }
unify_co' co1@(TyConAppCo _ _) (UnsafeCo lty2 rty2)
  = do { let Pair lty1 rty1 = coercionKind co1
       ; unify_ty lty1 lty2
       ; unify_ty rty1 rty2 }

-- see Note [unify_co SymCo case]
unify_co' co1@(SymCo _) co2
  = unify_co_sym TrySwitchingSym co1 co2
unify_co' co1 co2@(SymCo _)
  = unify_co_sym TrySwitchingSym co1 co2

unify_co' (TransCo col1 cor1) (TransCo col2 cor2)
  = do { unify_co col1 col2
       ; unify_co cor1 cor2 }

unify_co' (NthCo n1 co1) (NthCo n2 co2)
  | n1 == n2
  = unify_co' co1 co2

unify_co' (LRCo lr1 co1) (LRCo lr2 co2)
  | lr1 == lr2
  = unify_co' co1 co2

unify_co' (InstCo co1 arg1) (InstCo co2 arg2)
  = do { unify_co co1 co2
       ; unify_co_arg arg1 arg2 }

unify_co' (CoherenceCo lco1 rco1) (CoherenceCo lco2 rco2)
  = do { unify_co lco1 lco2
       ; unify_co rco1 rco2 }

unify_co' (KindCo co1) (KindCo co2)
  = unify_co' co1 co2

unify_co' _ _ = maybeApart

-- See Note [unify_co SymCo case]
data SymFlag = TrySwitchingSym
             | DontTrySwitchingSym

unify_co_sym :: SymFlag -> Coercion -> Coercion -> UM ()
unify_co_sym _ (SymCo co1) (SymCo co2)
  = unify_co' co1 co2
unify_co_sym _ (SymCo co1) (UnsafeCo lty2 rty2)
  = unify_co' co1 (UnsafeCo rty2 lty2)
unify_co_sym _ (UnsafeCo lty1 rty1) (SymCo co2)
  = unify_co' (UnsafeCo rty1 lty1) co2

-- note that neither co1 nor co2 can be Refl, so we don't have to worry
-- about missing that catchall case in unify_co'
unify_co_sym TrySwitchingSym (SymCo co1) co2
  = unify_co_sym DontTrySwitchingSym co1 (SymCo co2)
unify_co_sym TrySwitchingSym co1 (SymCo co2)
  = unify_co_sym DontTrySwitchingSym (SymCo co1) co2
unify_co_sym _ _ _ = maybeApart

unify_co_arg :: CoercionArg -> CoercionArg -> UM ()
unify_co_arg (TyCoArg co1) (TyCoArg co2) = unify_co co1 co2
unify_co_arg (CoCoArg lco1 rco1) (CoCoArg lco2 rco2)
  = do { unify_co lco1 lco2
       ; unify_co rco1 rco2 }

unifyList :: Unifiable tyco => [tyco] -> [tyco] -> UM ()
unifyList orig_xs orig_ys
  = go orig_xs orig_ys
  where
    go []     []     = return ()
    go (x:xs) (y:ys) = do { unify x y
			  ; go xs ys }
    go _ _ = surelyApart

---------------------------------
uVar :: TyOrCo tyco =>
     -> TyCoVar           -- Variable to be unified
     -> tyco              -- with this tyco
     -> UM ()

uVar tv1 ty
 = do { -- Check to see whether tv1 is refined by the substitution
        subst <- getSubstEnv
      ; case (lookupVarEnv subst tv1) of
          Just ty' -> unify ty' ty        -- Yes, call back into unify
          Nothing  -> uUnrefined tv1 ty ty } -- No, continue

uUnrefined :: TyOrCo tyco
           => TyCoVar             -- variable to be unified
           -> tyco                -- with this tyco
           -> tyco                -- (version w/ expanded synonyms)
           -> UM ()

-- We know that tv1 isn't refined

uUnrefined tv1 ty2 ty2'
  | Just ty2'' <- tycoTcView ty2'
  = uUnrefined tv1 ty2 ty2''	-- Unwrap synonyms
		-- This is essential, in case we have
		--	type Foo a = a
		-- and then unify a ~ Foo a

uUnrefined tv1 ty2 ty2'
  | Just tv2 <- getVar_maybe ty2'
  = do { tv1' <- umRnOccL tv1
       ; tv2' <- umRnOccR tv2
       ; when (tv1' /= tv2') $ do -- when they are equal, success: do nothing
       { subst <- getSubstEnv
          -- Check to see whether tv2 is refined     
       ; case lookupVarEnv subst tv2 of
           Just ty' -> uUnrefined tv1 ty' ty'
           Nothing  -> do
       {   -- So both are unrefined
       ; when mustUnifyKind ty2 $ unify_ty (tyVarKind tv1) (tyVarKind tv2)

           -- And then bind one or the other, 
           -- depending on which is bindable
	   -- NB: unlike TcUnify we do not have an elaborate sub-kinding 
	   --     story.  That is relevant only during type inference, and
           --     (I very much hope) is not relevant here.
       ; b1 <- tvBindFlag tv1
       ; b2 <- tvBindFlag tv2
       ; let ty1 = mkVar tv1
       ; case (b1, b2) of
           (Skolem, Skolem) -> maybeApart  -- See Note [Apartness with skolems]
           (BindMe, _)      -> do { checkRnEnvR ty2 -- make sure ty2 is not a local
                                  ; extendEnv tv1 ty2 }
           (_, BindMe)      -> do { checkRnEnvL ty1 -- ditto for ty1
                                  ; extendEnv tv2 ty1 }}}}

uUnrefined tv1 ty2 ty2'	-- ty2 is not a type variable
  = do { occurs <- elemNiSubstSet tv1 (tyCoVarsOf ty2')
       ; if occurs 
         then surelyApart               -- Occurs check
         else do
       { unify k1 k2
       ; bindTv tv1 ty2 }	-- Bind tyvar to the synonym if poss
  where
    k1 = tyVarKind tv1
    k2 = getKind ty2'

elemNiSubstSet :: TyCoVar -> TyCoVarSet -> UM Bool
elemNiSubstSet v set
  = do { tsubst <- getTvSubstEnv
       ; csubst <- getCvSubstEnv
       ; return $ v `elemVarSet` niSubstTvSet tsubst csubst set }

bindTv :: TyOrCo tyco => TyCoVar -> tyco -> UM ()
bindTv tv ty	-- ty is not a variable
  = do  { checkRnEnvR ty -- make sure ty mentions no local variables
        ; b <- tvBindFlag tv
	; case b of
	    Skolem -> maybeApart  -- See Note [Apartness with skolems]
	    BindMe -> extendEnv tv ty
	}
\end{code}

%************************************************************************
%*									*
	        TyOrCo class
%*									*
%************************************************************************

\begin{code}

class Unifiable tyco => TyOrCo tyco where
  getSubstEnv   :: UM (VarEnv tyco)
  tycoTcView    :: tyco -> Maybe tyco
  getVar_maybe  :: tyco -> Maybe TyCoVar
  mkVar         :: TyCoVar -> tyco
  extendEnv     :: TyCoVar -> tyco -> UM ()
  getKind       :: tyco -> Type
  mustUnifyKind :: tyco -> Bool -- the parameter is really a type proxy

instance TyOrCo Type where
  getSubstEnv     = getTvSubstEnv
  tycoTcView      = tcView
  getVar_maybe    = repGetTyVar_maybe
  mkVar           = mkOnlyTyVarTy
  extendEnv       = extendTvEnv
  getKind         = typeKind
  mustUnifyKind _ = True

instance TyOrCo Coercion where
  getSubstEnv     = getCvSubstEnv
  tycoTcView _    = Nothing
  getVar_maybe    = getCoVar_maybe
  mkVar           = mkCoVarCo
  extendEnv       = extendCvEnv
  getKind         = coercionType -- not coercionKind!
  mustUnifyKind _ = False -- done in unify_co, don't need in unify_co'

\end{code}

%************************************************************************
%*									*
		Binding decisions
%*									*
%************************************************************************

\begin{code}
data BindFlag 
  = BindMe	-- A regular type variable

  | Skolem	-- This type variable is a skolem constant
		-- Don't bind it; it only matches itself
\end{code}


%************************************************************************
%*									*
		Unification monad
%*									*
%************************************************************************

\begin{code}
data UnifFailure = UFMaybeApart
                 | UFSurelyApart

newtype UM a = UM { unUM :: (TyVar -> BindFlag) -- the user-supplied BingFlag function
                         -> RnEnv2              -- the renaming env for local variables
                         -> TyCoVarSet          -- set of all local variables
                         -> TvSubstEnv -> CvSubstEnv -- substitutions
		         -> Either UnifFailure ((TvSubstEnv, CvSubstEnv), a) }

instance Monad UM where
  return a = UM (\_ _ _ tsubst csubst -> Right ((tsubst, csubst), a))
  fail _   = UM (\_ _ _ _ _ -> Left UFSurelyApart) -- failed pattern match
  m >>= k  = UM (\tvs rn_env locals tsubst csubst ->
                 case unUM m tvs rn_env locals tsubst csubst of
		   Right ((tsubst', csubst'), v)
                     -> unUM (k v) tvs rn_env locals tsubst' csubst'
		   Left f  -> Left f)

initUM :: (TyVar -> BindFlag)
       -> TyCoVarSet  -- set of variables in scope
       -> UM TCvSubst -> ApartResult
initUM badtvs vars um
  = case unUM um badtvs rn_env emptyVarSet emptyTvSubstEnv emptyCvSubstEnv of
      Right subst        -> NotApart subst
      Left UFMaybeApart  -> MaybeApart
      Left UFSurelyApart -> SurelyApart
  where
    rn_env = mkRnEnv2 (mkInScopeSet vars)
    
tvBindFlag :: TyVar -> UM BindFlag
tvBindFlag tv = UM $ \tv_fn rn_env locals tsubst csubst ->
  Right ((tsubst, csubst), if tv `elemVarSet` locals then Skolem else tv_fn tv)

getTvSubstEnv :: UM TvSubstEnv
getTvSubstEnv = UM $ \_ _ _ tsubst csubst -> Right ((tsubst, csubst), tsubst)

extendTvEnv :: TyVar -> Type -> UM ()
extendTvEnv tv ty = UM $ \_ _ _ tsubst csubst ->
  let tsubst' = extendVarEnv tsubst tv ty in
  Right ((tsubst', csubst), ())

getCvSubstEnv :: UM CvSubstEnv
getCvSubstEnv = UM $ \_ _ _ tsubst csubst -> Right ((tsubst, csubst), csubst)

extendCvEnv :: CoVar -> Coercion -> UM ()
extendCvEnv cv co = UM $ \_ _ _ tsubst csubst ->
  let csubst' = extendVarEnv csubst cv co in
  Right ((tsubst, csubst'), ())

umRnBndr2 :: TyCoVar -> TyCoVar -> UM a -> UM a
umRnBndr2 v1 v2 thing = UM $ \tv_fn rn_env locals tsubst csubst ->
  let (rn_env', v3) = rnBndr2_var rn_env v1 v2
      locals'       = extendVarSetList locals [v1, v2, v3]
  in unUM thing tv_fn rn_env' locals' tsubst csubst

checkRnEnv :: TyOrCo tyco => (RnEnv2 -> tyco -> Bool) -> tyco -> UM ()
checkRnEnv inRnEnv tyco = UM $ \_ rn_env _ tsubst csubst ->
  let varset = tyCoVarsOf tyco in
  if any (inRnEnv rn_env) (varSetElems varset)
  then Left UFMaybeApart
  else Right ((tsubst, csubst), ())

checkRnEnvR :: TyOrCo tyco => tyco -> UM ()
checkRnEnvR = checkRnEnv inRnEnvR

checkRnEnvL :: TyOrCo tyco => tyco -> UM ()
checkRnEnvL = checkRnEnv inRnEnvL

umRnOccL :: TyCoVar -> UM TyCoVar
umRnOccL v = UM $ \_ rn_env _ tsubst csubst ->
  Right ((tsubst, csubst), rnOccL rn_env v)

umRnOccR :: TyCoVar -> UM TyCoVar
umRnOccR v = UM $ \_ rn_env _ tsubst csubst ->
  Right ((tsubst, csubst), rnOccR rn_env v)

umSwapRn :: UM a -> UM a
umSwapRn thing = UM $ \tv_fn rn_env locals tsubst csubst ->
  let rn_env' = rnSwap rn_env in
  unUM thing tv_fn rn_env' locals tsubst csubst

dontBeSoSure :: UM a -> UM a
dontBeSoSure thing = UM $ \ty_fn rn_env locals tsubst csubst ->
  case unUM thing ty_fn rn_env locals tsubst csubst of
    Left UFSurelyApart -> Left UFMaybeApart
    other              -> other

maybeApart :: UM a
maybeApart = UM (\_ _ _ _ _ -> Left UFMaybeApart)

surelyApart :: UM a
surelyApart = UM (\_ _ _ _ _ -> Left UFSurelyApart)
\end{code}

