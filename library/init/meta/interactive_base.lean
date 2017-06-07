/-
Copyright (c) 2016 Microsoft Corporation. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Leonardo de Moura
-/
prelude
import init.data.option.instances
import init.meta.lean.parser init.meta.tactic init.meta.has_reflect

open lean
open lean.parser

local postfix `?`:9001 := optional
local postfix *:9001 := many

namespace interactive
/-- (parse p) as the parameter type of an interactive tactic will instruct the Lean parser
    to run `p` when parsing the parameter and to pass the parsed value as an argument
    to the tactic. -/
@[reducible] meta def parse {α : Type} [has_reflect α] (p : parser α) : Type := α

inductive loc : Type
| wildcard : loc
| ns       : list name → loc

meta instance : has_reflect loc
| loc.wildcard := `(_)
| (loc.ns xs)  := `(_)

meta def loc.include_goal : loc → bool
| loc.wildcard := tt
| (loc.ns [])  := tt
| _            := ff

meta def loc.get_locals : loc → tactic (list expr)
| loc.wildcard := tactic.local_context
| (loc.ns xs)  := mmap tactic.get_local xs

namespace types
variables {α β : Type}

-- optimized pretty printer
meta def brackets (l r : string) (p : parser α) := tk l *> p <* tk r

meta def list_of (p : parser α) := brackets "[" "]" $ sep_by (skip_info (tk ",")) p

/-- A 'tactic expression', which uses right-binding power 2 so that it is terminated by
    '<|>' (rbp 2), ';' (rbp 1), and ',' (rbp 0). It should be used for any (potentially)
    trailing expression parameters. -/
meta def texpr := qexpr 2
/-- Parse an identifier or a '_' -/
meta def ident_ : parser name := ident <|> tk "_" *> return `_
meta def using_ident := (tk "using" *> ident)?
meta def with_ident_list := (tk "with" *> ident_*) <|> return []
meta def without_ident_list := (tk "without" *> ident*) <|> return []
meta def location := (tk "at" *> (tk "*" *> return loc.wildcard <|> (loc.ns <$> ident*))) <|> return (loc.ns [])
meta def qexpr_list := list_of (qexpr 0)
meta def opt_qexpr_list := qexpr_list <|> return []
meta def qexpr_list_or_texpr := qexpr_list <|> list.ret <$> texpr
meta def only_flag : parser bool := (tk "only" *> return tt) <|> return ff
end types

precedence only:0

/-- Use `desc` as the interactive description of `p`. -/
meta def with_desc {α : Type} (desc : format) (p : parser α) : parser α := p

open expr format tactic types
private meta def maybe_paren : list format → format
| []  := ""
| [f] := f
| fs  := paren (join fs)

private meta def unfold (e : expr) : tactic expr :=
do (expr.const f_name f_lvls) ← return e.get_app_fn | failed,
   env   ← get_env,
   decl  ← env.get f_name,
   new_f ← decl.instantiate_value_univ_params f_lvls,
   head_beta (expr.mk_app new_f e.get_app_args)

private meta def concat (f₁ f₂ : list format) :=
if f₁.empty then f₂ else if f₂.empty then f₁ else f₁ ++ [" "] ++ f₂

private meta def parser_desc_aux : expr → tactic (list format)
| `(ident)  := return ["id"]
| `(ident_) := return ["id"]
| `(qexpr) := return ["expr"]
| `(tk %%c) := list.ret <$> to_fmt <$> eval_expr string c
| `(cur_pos) := return []
| `(pure ._) := return []
| `(._ <$> %%p) := parser_desc_aux p
| `(skip_info %%p) := parser_desc_aux p
| `(set_goal_info_pos %%p) := parser_desc_aux p
| `(with_desc %%desc %%p) := list.ret <$> eval_expr format desc
| `(%%p₁ <*> %%p₂) := do
  f₁ ← parser_desc_aux p₁,
  f₂ ← parser_desc_aux p₂,
  return $ concat f₁ f₂
| `(%%p₁ <* %%p₂) := do
  f₁ ← parser_desc_aux p₁,
  f₂ ← parser_desc_aux p₂,
  return $ concat f₁ f₂
| `(%%p₁ *> %%p₂) := do
  f₁ ← parser_desc_aux p₁,
  f₂ ← parser_desc_aux p₂,
  return $ concat f₁ f₂
| `(many %%p) := do
  f ← parser_desc_aux p,
  return [maybe_paren f ++ "*"]
| `(optional %%p) := do
  f ← parser_desc_aux p,
  return [maybe_paren f ++ "?"]
| `(sep_by %%sep %%p) := do
  f₁ ← parser_desc_aux sep,
  f₂ ← parser_desc_aux p,
  return [maybe_paren f₂ ++ join f₁, " ..."]
| `(%%p₁ <|> %%p₂) := do
  f₁ ← parser_desc_aux p₁,
  f₂ ← parser_desc_aux p₂,
  return $ if f₁.empty then [maybe_paren f₂ ++ "?"] else
    if f₂.empty then [maybe_paren f₁ ++ "?"] else
    [paren $ join $ f₁ ++ [to_fmt " | "] ++ f₂]
| `(brackets %%l %%r %%p) := do
  f ← parser_desc_aux p,
  l ← eval_expr string l,
  r ← eval_expr string r,
  -- much better than the naive [l, " ", f, " ", r]
  return [to_fmt l ++ join f ++ to_fmt r]
| e          := do
  e' ← (do e' ← unfold e,
        guard $ e' ≠ e,
        return e') <|>
       (do f ← pp e,
        fail $ to_fmt "don't know how to pretty print " ++ f),
  parser_desc_aux e'

meta def param_desc : expr → tactic format
| `(parse %%p) := join <$> parser_desc_aux p
| `(opt_param %%t ._) := (++ "?") <$> pp t
| e := if is_constant e ∧ (const_name e).components.ilast = `itactic
  then return $ to_fmt "{ tactic }"
  else paren <$> pp e
end interactive

section macros
open interaction_monad
open interactive

private meta def parse_format : string → string → parser pexpr
| acc []            := pure ``(to_fmt %%(reflect acc))
| acc ('\n'::s)     :=
do f ← parse_format [] s,
   pure ``(to_fmt %%(reflect acc) ++ format.line ++ %%f)
| acc ('{'::'{'::s) := parse_format (acc ++ "{") s
| acc ('{'::s) :=
do (e, s) ← with_input (lean.parser.pexpr 0) s.reverse,
   '}'::s ← pure s.reverse | fail "'}' expected",
   f ← parse_format [] s,
   pure ``(to_fmt %%(reflect acc) ++ to_fmt %%e ++ %%f)
| acc (c::s) := parse_format (acc ++ [c]) s

reserve prefix `format! `:100
@[user_notation]
meta def format_macro (_ : parse $ tk "format!") (s : string) : parser pexpr :=
parse_format "" s.reverse

private meta def parse_sformat : string → string → parser pexpr
| acc []            := pure $ pexpr.of_expr (reflect acc)
| acc ('{'::'{'::s) := parse_sformat (acc ++ "{") s
| acc ('{'::s) :=
do (e, s) ← with_input (lean.parser.pexpr 0) s.reverse,
   '}'::s ← pure s.reverse | fail "'}' expected",
   f ← parse_sformat [] s,
   pure ``(to_string %%(reflect acc) ++ to_string %%e ++ %%f)
| acc (c::s) := parse_sformat (acc ++ [c]) s

reserve prefix `sformat! `:100
@[user_notation]
meta def sformat_macro (_ : parse $ tk "sformat!") (s : string) : parser pexpr :=
parse_sformat "" s.reverse
end macros