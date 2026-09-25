"""sql/*.sql・pages/*.md・README.md から Databricks 用の .ipynb を notebooks/ に生成する。

使い方: python3 tools/build_notebooks.py
- SQL は空行区切りの段落ごとに 1 セル。`run_sql(r"...")`（00_config で定義）で実行し、
  テーブル・View・関数名に config のカタログ・スキーマを自動で付ける。コメントだけの段落は Markdown セルにする。
- Exercise 7 のパラメータ（:h_xxx）用に、ウィジェット作成セル（Python）を自動で挿入する。
- SQL の「-- @config-begin 〜 -- @config-end」（USE CATALOG / USE SCHEMA）は除去し、
  代わりに `%run ./00_config` セルを入れる。カタログ・スキーマ名は config/00_config.py で一元管理する。
- config/00_config.py・notebook_src/*.py・tests/*.py（Databricks ソース形式）を .ipynb に変換する。
- dashboard/vehicle_profitability.lvdash.json を 08b のノートブックに埋め込む。
"""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "notebooks"
DASHBOARD_JSON = ROOT / "dashboard" / "vehicle_profitability.lvdash.json"

SQL_KEYWORD = re.compile(r"^(SELECT|UPDATE|FROM|JOIN|WHERE|ORDER|GROUP|DROP|ALTER|INSERT|CREATE|WITH|MERGE|USE)\b", re.I)
DELIMITER = re.compile(r"^[-=]{5,}$")
CONFIG_BLOCK = re.compile(r"-- @config-begin.*?-- @config-end\n", re.S)
RUN_CONFIG = "%run ./00_config"
SQL_NOTE = ("このノートブックの SQL は `run_sql()`（`00_config` で定義）で実行します。"
            "テーブル・View・関数の名前には、`00_config` のカタログ・スキーマが自動で付きます"
            "（例：`sales_actual` → `workspace.vehicle_alias_handson.sales_actual`）。"
            "**最初に `%run ./00_config` のセルを実行してください。**")
WIDGET_NAMES = ("h_collect", "h_research", "h_matching", "h_quality", "h_aggregate", "h_review")
CELL_SEP = "# COMMAND ----------"
EXPECT_ERROR = "-- @expect-error"

DROP_SCHEMA = """# 00_config で設定したスキーマを丸ごと削除する（テーブル・View・関数もすべて消えます）
CONFIRM_DROP = False  # ← 削除対象を確認してから True にして実行

if CONFIRM_DROP:
    spark.sql(f"DROP SCHEMA IF EXISTS `{CATALOG}`.`{SCHEMA}` CASCADE")
    print(f"🗑️ 削除しました: {FQ_SCHEMA}")
else:
    print(f"削除対象: {FQ_SCHEMA}（CONFIRM_DROP = True にすると削除します）")"""

WIDGETS = """# Exercise 7-2 用のパラメータ（ノートブック上部のウィジェットに自分の想定時間を入力）
for name, default in [("h_collect", "8"), ("h_research", "5"), ("h_matching", "7"),
                      ("h_quality", "4"), ("h_aggregate", "2"), ("h_review", "6")]:
    dbutils.widgets.text(name, default)"""


def md_cell(text):
    return {"cell_type": "markdown", "metadata": {}, "source": text.splitlines(keepends=True)}


def code_cell(text):
    return {"cell_type": "code", "execution_count": None, "metadata": {}, "outputs": [],
            "source": text.splitlines(keepends=True)}


def notebook(cells, name):
    return {
        "cells": cells,
        "metadata": {
            "application/vnd.databricks.v1+notebook": {"notebookName": name, "language": "python"},
            "kernelspec": {"display_name": "Python 3", "language": "python", "name": "python3"},
            "language_info": {"name": "python"},
        },
        "nbformat": 4,
        "nbformat_minor": 4,
    }


def comment_block_to_md(lines):
    body = [re.sub(r"^--\s?", "", l) for l in lines]
    body = [b for b in body if not DELIMITER.match(b.strip())]
    # コメントアウトされた SQL（キーワード始まりの行とその継続行）は ```sql で囲む
    out, in_sql = [], False
    for b in body:
        is_sql = bool(SQL_KEYWORD.match(b.strip())) or (in_sql and b.startswith(" ") and "※" not in b)
        if is_sql and not in_sql:
            out.append("```sql")
        if not is_sql and in_sql:
            out.append("```")
        out.append(b.rstrip() if is_sql else b.strip() + "  ")
        in_sql = is_sql
    if in_sql:
        out.append("```")
    if out[0] == "```sql":
        return "（任意・コメントアウト済みの SQL。必要に応じて新しいセルにコピーして実行）\n" + "\n".join(out)
    title = out[0].strip()
    heading = "## " if re.match(r"^\d+-\d+\.|^DQ-|^[0-9]+\.", title) else "### "
    if "Exercise" in title or ".sql" in title:
        heading = "# "
    return heading + title + ("\n\n" + "\n".join(out[1:]) if out[1:] else "")


def sql_to_cells(path):
    cells = []
    text = CONFIG_BLOCK.sub("", path.read_text(encoding="utf-8"))
    paragraphs = re.split(r"\n\s*\n", text.strip())
    for para in paragraphs:
        lines = para.splitlines()
        lines = [l for l in lines if l.strip() != EXPECT_ERROR]
        if all(l.strip().startswith("--") for l in lines):
            cells.append(md_cell(comment_block_to_md(lines)))
            continue
        # 先頭のコメント行（見出し・説明）は Markdown セルに分離する
        n = 0
        while lines[n].strip().startswith("--"):
            n += 1
        if n:
            cells.append(md_cell(comment_block_to_md(lines[:n])))
        body = "\n".join(lines[n:])
        if EXPECT_ERROR in para:
            # わざと失敗させる文は「すべて実行」が止まらないよう、Python で例外を捕まえて表示する
            stmt = body.strip().rstrip(";")
            cells.append(code_cell(
                "# 想定どおりエラーになることを確認するセル（エラー内容を表示して次へ進む）\n"
                f'stmt = r"""{stmt}"""\n'
                "try:\n"
                "    spark.sql(qualify(stmt))\n"
                '    print("⚠️ 成功してしまいました（想定外）")\n'
                "except Exception as e:\n"
                '    print("✅ 想定どおり失敗しました:", str(e).splitlines()[0][:300])'))
            continue
        assert '"""' not in body, f"{path.name}: SQL に三重引用符は使えません"
        if ":h_collect" in body:
            cells.append(code_cell(WIDGETS))
            args = "{k: dbutils.widgets.get(k) for k in " + repr(WIDGET_NAMES) + "}"
            cells.append(code_cell(f'run_sql(r"""\n{body}\n""", args={args})'))
        else:
            cells.append(code_cell(f'run_sql(r"""\n{body}\n""")'))
    # タイトル（先頭の Markdown セル）の直後で共通設定を読み込む
    cells.insert(1, code_cell(RUN_CONFIG))
    cells.insert(2, md_cell(SQL_NOTE))
    if path.stem == "99_cleanup":
        cells.append(code_cell(DROP_SCHEMA))
    return cells


def databricks_source_to_cells(path):
    """Databricks ソース形式（# COMMAND ---------- 区切り、# MAGIC %md）をセルに変換する。"""
    text = path.read_text(encoding="utf-8").replace("# Databricks notebook source\n", "", 1)
    # ダッシュボード定義（JSON）をデプロイ用ノートブックに埋め込む
    text = text.replace("__DASHBOARD_JSON__", DASHBOARD_JSON.read_text(encoding="utf-8").strip())
    cells = []
    for chunk in text.split(CELL_SEP):
        chunk = chunk.strip("\n")
        if not chunk:
            continue
        if chunk.startswith("# MAGIC"):
            lines = [re.sub(r"^# MAGIC ?", "", l) for l in chunk.splitlines()]
            if lines[0].startswith("%md"):
                cells.append(md_cell("\n".join(lines[1:] if lines[0].strip() == "%md" else lines)))
            else:
                cells.append(code_cell("\n".join(lines)))
        else:
            cells.append(code_cell(chunk))
    return cells


def md_to_cells(path):
    """Markdown を ## 見出し単位で分割して Markdown セルにする。"""
    text = path.read_text(encoding="utf-8")
    parts = re.split(r"(?m)^(?=## )", text)
    return [md_cell(p.strip()) for p in parts if p.strip()]


def main():
    OUT.mkdir(exist_ok=True)
    targets = [("00_README_ハンズオンガイド", md_to_cells(ROOT / "README.md")),
               ("00_config", databricks_source_to_cells(ROOT / "config" / "00_config.py"))]
    for sql in sorted((ROOT / "sql").glob("*.sql")):
        targets.append((sql.stem, sql_to_cells(sql)))
    for src in sorted((ROOT / "notebook_src").glob("*.py")) + sorted((ROOT / "tests").glob("*.py")):
        targets.append((src.stem, databricks_source_to_cells(src)))
    for page in sorted((ROOT / "pages").glob("*.md")):
        targets.append(("page_" + page.stem, md_to_cells(page)))
    for name, cells in targets:
        (OUT / f"{name}.ipynb").write_text(
            json.dumps(notebook(cells, name), ensure_ascii=False, indent=1), encoding="utf-8")
        print(f"{name}.ipynb: {len(cells)} cells")


if __name__ == "__main__":
    main()
