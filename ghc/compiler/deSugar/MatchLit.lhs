%
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1996
%
\section[MatchLit]{Pattern-matching literal patterns}

\begin{code}
#include "HsVersions.h"

module MatchLit ( matchLiterals ) where

IMP_Ubiq()
#if defined(__GLASGOW_HASKELL__) && __GLASGOW_HASKELL__ <= 201
IMPORT_DELOOPER(DsLoop)		-- break match-ish and dsExpr-ish loops
#else
import {-# SOURCE #-} Match
import {-# SOURCE #-} DsExpr ( dsExpr )
#endif

import HsSyn		( HsLit(..), OutPat(..), HsExpr(..), Fixity,
			  Match, HsBinds, Stmt(..), DoOrListComp, HsType, ArithSeqInfo )
import TcHsSyn		( SYN_IE(TypecheckedHsExpr), SYN_IE(TypecheckedHsBinds),
			  SYN_IE(TypecheckedPat)
			)
import CoreSyn		( SYN_IE(CoreExpr), SYN_IE(CoreBinding), GenCoreExpr(..), GenCoreBinding(..) )
import Id		( GenId {- instance Eq -}, SYN_IE(Id) )

import DsMonad
import DsUtils

import Literal		( mkMachInt, Literal(..) )
import Maybes		( catMaybes )
import Type		( isPrimType, SYN_IE(Type) )
import Util		( panic, assertPanic )
\end{code}

\begin{code}
matchLiterals :: [Id]
	      -> [EquationInfo]
	      -> [EquationInfo]		-- Shadows
	      -> DsM MatchResult
\end{code}

This first one is a {\em special case} where the literal patterns are
unboxed numbers (NB: the fiddling introduced by @tidyEqnInfo@).  We
want to avoid using the ``equality'' stuff provided by the
typechecker, and do a real ``case'' instead.  In that sense, the code
is much like @matchConFamily@, which uses @match_cons_used@ to create
the alts---here we use @match_prims_used@.

\begin{code}
matchLiterals all_vars@(var:vars) eqns_info@(EqnInfo (LitPat literal lit_ty : ps1) _ : eqns) shadows
  = -- GENERATE THE ALTS
    match_prims_used vars eqns_info shadows `thenDs` \ prim_alts ->

    -- MAKE THE PRIMITIVE CASE
    mkCoPrimCaseMatchResult var prim_alts
  where
    match_prims_used _ [{-no more eqns-}] _ = returnDs []

    match_prims_used vars eqns_info@(EqnInfo ((LitPat literal lit_ty):ps1) _ : eqns) shadows
      = let
	    (shifted_eqns_for_this_lit, eqns_not_for_this_lit)
	      = partitionEqnsByLit Nothing literal eqns_info
	    (shifted_shadows_for_this_lit, shadows_not_for_this_lit)
	      = partitionEqnsByLit Nothing literal shadows
	in
	-- recursive call to make other alts...
	match_prims_used vars eqns_not_for_this_lit shadows_not_for_this_lit	`thenDs` \ rest_of_alts ->

	-- (prim pats have no args; no selectMatchVars as in match_cons_used)
	-- now do the business to make the alt for _this_ LitPat ...
	match vars shifted_eqns_for_this_lit shifted_shadows_for_this_lit	`thenDs` \ match_result ->
	returnDs (
	    (mk_core_lit lit_ty literal, match_result)
	    : rest_of_alts
	)
      where
	mk_core_lit :: Type -> HsLit -> Literal

	mk_core_lit ty (HsIntPrim     i) = mkMachInt  i
	mk_core_lit ty (HsCharPrim    c) = MachChar   c
	mk_core_lit ty (HsStringPrim  s) = MachStr    s
	mk_core_lit ty (HsFloatPrim   f) = MachFloat  f
	mk_core_lit ty (HsDoublePrim  d) = MachDouble d
	mk_core_lit ty (HsLitLit      s) = ASSERT(isPrimType ty)
					   MachLitLit s (panic "MatchLit.matchLiterals:mk_core_lit:HsLitLit; typePrimRep???")
    	mk_core_lit ty other	         = panic "matchLiterals:mk_core_lit:unhandled"
\end{code}

\begin{code}
matchLiterals all_vars@(var:vars) eqns_info@(EqnInfo ((NPat literal lit_ty eq_chk):ps1) _ : eqns) shadows
  = let
	(shifted_eqns_for_this_lit, eqns_not_for_this_lit)
	  = partitionEqnsByLit Nothing literal eqns_info
	(shifted_shadows_for_this_lit, shadows_not_for_this_lit)
	  = partitionEqnsByLit Nothing literal shadows
    in
    dsExpr (HsApp eq_chk (HsVar var))					`thenDs` \ pred_expr ->
    match vars shifted_eqns_for_this_lit shifted_shadows_for_this_lit	`thenDs` \ inner_match_result ->
    mkGuardedMatchResult pred_expr inner_match_result			`thenDs` \ match_result1 ->

    if (null eqns_not_for_this_lit)
    then
	returnDs match_result1
    else
	matchLiterals all_vars eqns_not_for_this_lit shadows_not_for_this_lit 	`thenDs` \ match_result2 ->
	combineMatchResults match_result1 match_result2
\end{code}

For an n+k pattern, we use the various magic expressions we've been given.
We generate:
\begin{verbatim}
    if ge var lit then
	let n = sub var lit
	in  <expr-for-a-successful-match>
    else
	<try-next-pattern-or-whatever>
\end{verbatim}


\begin{code}
matchLiterals all_vars@(var:vars) eqns_info@(EqnInfo ((NPlusKPat master_n k ty ge sub):ps1) _ : eqns) shadows
  = let
	(shifted_eqns_for_this_lit, eqns_not_for_this_lit)
	  = partitionEqnsByLit (Just master_n) k eqns_info
	(shifted_shadows_for_this_lit, shadows_not_for_this_lit)
	  = partitionEqnsByLit (Just master_n) k shadows
    in
    match vars shifted_eqns_for_this_lit shifted_shadows_for_this_lit	`thenDs` \ inner_match_result ->

    dsExpr (HsApp ge (HsVar var))		`thenDs` \ ge_expr ->
    dsExpr (HsApp sub (HsVar var))		`thenDs` \ nminusk_expr ->

    mkGuardedMatchResult
	ge_expr
	(mkCoLetsMatchResult [NonRec master_n nminusk_expr] inner_match_result)
					`thenDs` \ match_result1 ->

    if (null eqns_not_for_this_lit)
    then 
	returnDs match_result1
    else 
	matchLiterals all_vars eqns_not_for_this_lit shadows_not_for_this_lit 	`thenDs` \ match_result2 ->
	combineMatchResults match_result1 match_result2
\end{code}

Given a blob of LitPats/NPats, we want to split them into those
that are ``same''/different as one we are looking at.  We need to know
whether we're looking at a LitPat/NPat, and what literal we're after.

\begin{code}
partitionEqnsByLit :: Maybe Id 	-- (Just v) for N-plus-K patterns, where v
				-- is the "master" variable;
				-- Nothing for NPats and LitPats
		   -> HsLit
		   -> [EquationInfo]
		   -> ([EquationInfo], 	-- These ones are for this lit, AND
					-- they've been "shifted" by stripping
					-- off the first pattern
		       [EquationInfo]	-- These are not for this lit; they
					-- are exactly as fed in.
		      )

partitionEqnsByLit nPlusK lit eqns
  = ( \ (xs,ys) -> (catMaybes xs, catMaybes ys))
	(unzip (map (partition_eqn nPlusK lit) eqns))
  where
    partition_eqn :: Maybe Id -> HsLit -> EquationInfo ->
		(Maybe EquationInfo, Maybe EquationInfo)

    partition_eqn Nothing lit (EqnInfo (LitPat k _ : remaining_pats) match_result)
      | lit `eq_lit` k  = (Just (EqnInfo remaining_pats match_result), Nothing)
			  -- NB the pattern is stripped off the EquationInfo

    partition_eqn Nothing lit (EqnInfo (NPat k _ _ : remaining_pats) match_result)
      | lit `eq_lit` k  = (Just (EqnInfo remaining_pats match_result), Nothing)
			  -- NB the pattern is stripped off the EquationInfo

    partition_eqn (Just master_n) lit  (EqnInfo (NPlusKPat n k _ _ _ : remaining_pats) match_result)
      | lit `eq_lit` k  = (Just (EqnInfo remaining_pats new_match_result), Nothing)
			  -- NB the pattern is stripped off the EquationInfo
      where
	new_match_result | master_n == n = match_result
			 | otherwise 	 = mkCoLetsMatchResult [NonRec n (Var master_n)] match_result

	-- Wild-card patterns, which will only show up in the shadows, go into both groups
    partition_eqn nPlusK lit eqn@(EqnInfo (WildPat _ : remaining_pats) match_result)
			= (Just (EqnInfo remaining_pats match_result), Just eqn)

	-- Default case; not for this pattern
    partition_eqn nPlusK lit eqn = (Nothing, Just eqn)

-- ToDo: meditate about this equality business...

eq_lit (HsInt  i1)   	 (HsInt  i2)       = i1 == i2
eq_lit (HsFrac f1) 	 (HsFrac f2)       = f1 == f2

eq_lit (HsIntPrim i1)	 (HsIntPrim i2)    = i1 == i2
eq_lit (HsFloatPrim f1)  (HsFloatPrim f2)  = f1 == f2
eq_lit (HsDoublePrim d1) (HsDoublePrim d2) = d1 == d2
eq_lit (HsChar c1) 	 (HsChar c2)       = c1 == c2
eq_lit (HsCharPrim c1)	 (HsCharPrim c2)   = c1 == c2
eq_lit (HsString s1)	 (HsString s2)     = s1 == s2
eq_lit (HsStringPrim s1) (HsStringPrim s2) = s1 == s2
eq_lit (HsLitLit s1)	 (HsLitLit s2)     = s1 == s2 -- ToDo: ??? (dubious)
eq_lit other1	      	 other2		   = panic "matchLiterals:eq_lit"
\end{code}
