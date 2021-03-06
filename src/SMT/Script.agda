open import SMT.Theory

module SMT.Script {theory : Theory} (printable : Printable theory) (parsable : Parsable theory) where

open import Data.Fin as Fin using (Fin; suc; zero)
open import Data.List as List using (List; _∷_; []; _++_)
open import Data.List.NonEmpty as List⁺ using (List⁺; _∷_)
open import Data.Product as Prod using (∃; ∃-syntax; _,_)
open import Relation.Nullary using (Dec; yes; no)
open import Relation.Nullary.Decidable using (True)
open import Relation.Binary.PropositionalEquality using (_≡_; refl)
open import SMT.Logics
open import Data.Environment as Env using (Env; _∷_; [])

open import Category.Monad
open import Category.Monad.State as StateCat using (RawIMonadState; IStateT)
open import Codata.Musical.Stream as Stream using (Stream)
open import Data.Char as Char using (Char)
open import Data.Maybe as Maybe using (Maybe; just; nothing)
open import Data.Nat as Nat using (ℕ)
open import Data.Nat.Show renaming (show to showℕ)
open import Data.Product as Product using (_×_; _,_; -,_; proj₁; proj₂)
open import Data.String as String using (String)
open import Data.Unit as Unit using (⊤)
open import Data.Vec as Vec using (Vec)
open import Function using (const; id; _∘_; _$_)
import Function.Identity.Categorical as Identity
open import Text.Parser.String as P hiding (_>>=_)
open import Reflection using (con; vArg)

open import SMT.Script.Base theory public
open import SMT.Script.Names theory

open Theory theory
open Printable printable
open Parsable parsable

private
  variable
    σ σ′    : Sort
    Γ Γ′ δΓ : Ctxt
    Δ Δ′    : Ctxt
    Σ       : Signature σ
    Σ′      : Signature σ′
    ξ ξ′    : OutputType
    Ξ Ξ′ δΞ : OutputCtxt


-- |Create an S-expression from a list of strings.
--
-- @
--   mkSTerm ("*" ∷ "4" ∷ "5") ≡ "(* 4 5)"
-- @
--
mkSTerm : List String → String
mkSTerm = String.parens ∘ String.unwords


-- * Variable parsers

-- |Environment of variable parsers.
VarParsers : Ctxt → Set
VarParsers = Env (λ σ Γ → ∀[ Parser ((σ ∷ Γ) ∋ σ) ])

-- |Construct a single variable parser from an environment of variable parsers.
mkVarParser : VarParsers Γ → ∀[ Parser (∃[ σ ] (Γ ∋ σ)) ]
mkVarParser []            = fail
mkVarParser (p ∷ env) {x} = (-,_ <$> p {x}) <|> (Prod.map id extendVar <$> mkVarParser env {x})


-- * Output parsers

-- |Mapping from output types to parser types.
OutputParser : OutputType → Set
OutputParser ξ = ∀[ Parser (Output ξ) ]

-- |Mapping from output contexts to parser types.
OutputParsers : OutputCtxt → Set
OutputParsers Ξ = Env (λ ξ _Ξ → OutputParser ξ) Ξ

-- |Parse a satisfiability result.
pSat : ∀[ Parser Sat ]
pSat = sat     <$ lexeme "sat"
   <|> unsat   <$ lexeme "unsat"
   <|> unknown <$ lexeme "unknown"

_ : pSat parses "sat"
_ = ! sat

_ : pSat parses "unsat"
_ = ! unsat

_ : pSat parses "unknown"
_ = ! unknown

_ : pSat rejects "dogfood"
_ = _


-- |Construct a definitions parser from a variable parser.
--
-- @
--   (define-fun x0 () Int (- 1))
-- @
--
mkDefnParser : ∀[ Parser (Var Γ) ] → ∀[ Parser (Defn Γ) ]
mkDefnParser {Γ} pVar = withSpaces (guardM checkDefn pVarVal)
  where
    pVarVal : ∀[ Parser (Var Γ × Val) ]
    pVarVal =
      parens (box (lexeme "define-fun" &> box (pVar <&>
        box (lexeme "()" &> box (parseSort P.>>= λ σ → box (-,_ <$> parseValue σ))))))

    checkDefn : Var Γ × Val → Maybe (Defn Γ)
    checkDefn ((σ , i) , (σ′ , v)) with σ ≟-Sort σ′
    ... | yes refl = just (σ , i , v)
    ... | no  _    = nothing


-- |Construct a definition-list parser from a variable parser.
mkDefnsParser : ∀[ Parser (Var Γ) ] → ∀[ Parser (List⁺ (Defn Γ)) ]
mkDefnsParser {Γ} pVar =
  withSpaces (parens (box (lexeme "model" &> box (list⁺ (mkDefnParser {Γ} pVar)))))


private
  MaybeModel : Ctxt → Set
  MaybeModel Γ = Env (λ σ _Γ → List (Value σ)) Γ

  insertMM : ∃[ σ ] (Γ ∋ σ × Value σ) → MaybeModel Γ → MaybeModel Γ
  insertMM {.σ ∷ Γ} (σ , (Fin.zero  , refl) , v) (vs ∷ env) = (v ∷ vs) ∷ env
  insertMM {σ′ ∷ Γ} (σ , (Fin.suc i , p)    , v) (vs ∷ env) = vs ∷ insertMM (σ , (i , p) , v) env

  mkMM : List (Defn Γ) → MaybeModel Γ
  mkMM {Γ} []       = Env.repeat (λ _σ _Γ → []) Γ
  mkMM {Γ} (v ∷ vs) = insertMM v (mkMM vs)

  fromSingleton : {A : Set} → List A → Maybe A
  fromSingleton [] = nothing
  fromSingleton (v ∷ []) = just v
  fromSingleton (_ ∷ _ ∷ _) = nothing

  checkMM : MaybeModel Γ → Maybe (Model Γ)
  checkMM [] = just []
  checkMM (vs ∷ env) = Maybe.zipWith _∷_ (fromSingleton vs) (checkMM env)


-- |Construct a model parser from a variable parser.
mkModelParser : ∀[ Parser (Var Γ) ] → ∀[ Parser (Model Γ) ]
mkModelParser {Γ} pVar = pSat P.>>= λ { sat → box pModel ; _ → box fail }
  where
    -- Insert each definition into a model, and check if it is complete.
    pModel : ∀[ Parser (Model Γ) ]
    pModel = guardM checkMM (mkMM ∘ List⁺.toList <$> mkDefnsParser {Γ} pVar)

mkOutputParsers⁺ : OutputParsers (ξ ∷ Ξ) → ∀[ Parser (Outputs (ξ ∷ Ξ)) ]
mkOutputParsers⁺ (op ∷ [])          = (_∷ []) <$> op
mkOutputParsers⁺ (op ∷ ops@(_ ∷ _)) = _∷_ <$> op <*> box (mkOutputParsers⁺ ops)


-- * Name state monad

NameState : (Γ Γ′ : Ctxt) → Set → Set
NameState Γ Γ′ A = IStateT (λ Γ → Names Γ × VarParsers Γ) id Γ Γ′ A

-- When showing terms, we need to pass around a name state,
-- for which we'll use an indexed monad, indexed by the context,
-- so we bring the functions from the indexed monad in scope.
private
  monadStateNameState =
    StateCat.StateTIMonadState (λ Γ → Names Γ × VarParsers Γ) Identity.monad

open RawIMonadState monadStateNameState
  using (return; _>>=_; _>>_; put; get; modify)

freshNameS : (σ : Sort) → NameState Γ (σ ∷ Γ) Name
freshNameS σ = do
  (ns , vps) ← get
  let (n , ns) = freshName σ ns
  let vps = ((Fin.zero , refl) <$ withSpaces (exacts n)) ∷ vps
  put (ns , vps)
  return n

dropNameS : NameState (σ ∷ Γ) Γ ⊤
dropNameS = do
  (ns , _ ∷ vps) ← get
  put (dropName ns , vps)
  return _

lookupNameS : (i : Γ ∋ σ) → NameState Γ Γ Name
lookupNameS (i , _p) = do
  (ns , _vps) ← get
  return $ Env.lookup (Names.nameEnv ns) i


-- * Printing functions

mutual

  -- |Show a term as an S-expression.
  showTermS : Term Γ σ → NameState Γ Γ String
  showTermS (var i) = do
    n ← lookupNameS i
    return $ showName n
  showTermS (lit l) = do
    return $ showLiteral l
  showTermS (app x xs) = do
    let x = showIdentifier x
    xs ← showArgsS xs
    return $ mkSTerm (x ∷ xs)
  showTermS (forAll σ x) = do
    n ← freshNameS σ
    x ← showTermS x
    dropNameS
    return $ mkSTerm ("forall" ∷ mkSTerm (mkSTerm (showName n ∷ showSort σ ∷ []) ∷ []) ∷ x ∷ [])
  showTermS (exists σ x) = do
    n ← freshNameS σ
    x ← showTermS x
    dropNameS
    return $ mkSTerm ("exists" ∷ mkSTerm (mkSTerm (showName n ∷ showSort σ ∷ []) ∷ []) ∷ x ∷ [])

  showArgsS : Args Γ Δ → NameState Γ Γ (List String)
  showArgsS []       = return []
  showArgsS (x ∷ xs) = do x ← showTermS x; xs ← showArgsS xs; return (x ∷ xs)


-- |Show a command as an S-expression, and build up an environment of output parsers.
showCommandS : Command Γ δΓ δΞ → NameState Γ (δΓ ++ Γ) (String × OutputParsers δΞ)
showCommandS (set-logic l) = do
  return $ mkSTerm ("set-logic" ∷ showLogic l ∷ []) , []
showCommandS (declare-const σ) = do
  n ← freshNameS σ
  return $ mkSTerm ("declare-const" ∷ showName n ∷ showSort σ ∷ []) , []
showCommandS (assert x) = do
  x ← showTermS x
  return $ mkSTerm ("assert" ∷ x ∷ []) , []
showCommandS check-sat = do
  return $ mkSTerm ("check-sat" ∷ []) , pSat ∷ []
showCommandS get-model = do
  (_ns , vps) ← get
  return $ String.unlines ( mkSTerm ("check-sat" ∷ [])
                          ∷ mkSTerm ("get-model" ∷ []) ∷ [] )
         , mkModelParser (mkVarParser vps) ∷ []

-- |Show a script as an S-expression, and build up an environment of output parsers.
showScriptS : Script Γ Γ′ Ξ → NameState Γ Γ′ (List String × OutputParsers Ξ)
showScriptS [] = do
  return $ [] , []
showScriptS (cmd ∷ scr) = do
  (cmd , ops₁) ← showCommandS cmd
  (scr , ops₂) ← showScriptS scr
  return $ cmd ∷ scr , Env.append id ops₂ ops₁

-- |Show a script as an S-expression, and return an environment of output parsers.
showScript : Script [] Γ (ξ ∷ Ξ) → String × ∀[ Parser (Outputs (ξ ∷ Ξ)) ]
showScript scr = Prod.map String.unlines mkOutputParsers⁺ (proj₁ (showScriptS scr (x′es , [])))

-- |Get the variable parser for a script (for debugging purposes).
getVarParser : Script [] Γ Ξ → ∀[ Parser (∃[ σ ] (Γ ∋ σ)) ]
getVarParser scr = mkVarParser (proj₂ (proj₂ (showScriptS scr (x′es , []))))

-- -}
-- -}
-- -}
