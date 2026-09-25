# Databricks notebook source
# MAGIC %md
# MAGIC # 00_config：ハンズオン共通設定
# MAGIC
# MAGIC 各ノートブックの先頭セル `%run ./00_config` から読み込まれ、次を行います。
# MAGIC
# MAGIC 1. カタログ・スキーマ名を決める（下の `CONFIG` を編集）
# MAGIC 2. スキーマが無ければ作成する
# MAGIC 3. SQL を実行する関数 `run_sql()` を用意する。ハンズオンで使うテーブル・View・関数の名前に、**このカタログ・スキーマを自動で付けて**実行する
# MAGIC    （`USE` の状態に左右されないので、どのコンピュート・どのセルから実行しても同じスキーマを使う）
# MAGIC
# MAGIC **Free Edition では既定値のままで動きます**（既定カタログ `workspace` にスキーマを作成）。
# MAGIC 複数人で同じワークスペースを使う場合は、`schema` を `vehicle_alias_handson_<イニシャル>` のように人ごとに変えてください。
# MAGIC
# MAGIC ジョブのパラメータやウィジェットに `catalog` / `schema` / `warehouse_id` / `dashboard_parent_path` を指定した場合は、そちらが優先されます。

# COMMAND ----------

# ===== ここだけ編集してください =====
CONFIG = {
    "catalog": "workspace",               # Free Edition の既定カタログ。社内ワークスペースでは講師が用意したカタログ名
    "schema": "vehicle_alias_handson",    # 参加者ごとに分ける場合は vehicle_alias_handson_<イニシャル>
    "create_catalog": False,              # True: カタログが無ければ作成する（CREATE CATALOG 権限が必要）
    "warehouse_id": "",                   # 経営ダッシュボード（08b）で使う SQL Warehouse。空なら自動で選ぶ
    "dashboard_parent_path": "",          # 経営ダッシュボードの置き場所。空ならノートブックと同じフォルダ（Git フォルダで使う場合は外のフォルダを指定）
}

# COMMAND ----------

# 以下は編集不要
import re


def _param(name):
    """ウィジェット / ジョブパラメータに値があればそれを返す（無ければ None）。"""
    try:
        value = dbutils.widgets.get(name).strip()
        return value or None
    except Exception:
        return None


for key in ("catalog", "schema"):
    CONFIG[key] = _param(key) or CONFIG[key]
    if not re.fullmatch(r"[A-Za-z0-9_]+", CONFIG[key]):
        raise ValueError(f"{key} には英数字とアンダースコアのみ使えます: {CONFIG[key]!r}")

for key in ("warehouse_id", "dashboard_parent_path"):
    CONFIG[key] = _param(key) or CONFIG.get(key, "")

CATALOG = CONFIG["catalog"]
SCHEMA = CONFIG["schema"]
FQ_SCHEMA = f"{CATALOG}.{SCHEMA}"

if CONFIG["create_catalog"]:
    spark.sql(f"CREATE CATALOG IF NOT EXISTS `{CATALOG}`")
spark.sql(f"CREATE SCHEMA IF NOT EXISTS `{CATALOG}`.`{SCHEMA}` COMMENT 'Vehicle Profitability ハンズオン（架空データ）'")
spark.sql(f"USE CATALOG `{CATALOG}`")
spark.sql(f"USE SCHEMA `{SCHEMA}`")

# ハンズオンで作成・参照するオブジェクト。SQL 中のこれらの名前に「カタログ.スキーマ.」を付けて実行する
HANDSON_OBJECTS = [
    # テーブル
    "canonical_vehicle", "vehicle_alias_master", "alias_mapping_history", "development_plan", "sales_actual",
    "production_actual", "vehicle_bom", "effort_estimate", "tacit_knowledge_notes", "shipment_actual",
    "legacy_cost_sheet_lines", "sample_query_history", "evidence_weight", "alias_evidence",
    # View・Metric View
    "v_alias_approved", "v_sales_resolved", "v_production_resolved", "v_plan_resolved",
    "v_vehicle_monthly_profitability", "v_unresolved_records", "v_alias_review_queue", "v_dq_summary",
    "v_unresolved_codes", "v_unambiguous_names", "v_unambiguous_codes", "v_evidence_score",
    "mv_vehicle_profitability", "v_data_trust_summary", "v_exec_action_items",
    # 関数
    "norm_code", "norm_name",
]
_NAME_RE = re.compile(r"(?<![\w.`])(" + "|".join(sorted(HANDSON_OBJECTS, key=len, reverse=True)) + r")\b")


def _lex(sql):
    """SQL を (種類, 文字列) に分ける。文字列リテラル・識別子・コメントは書き換えない。"""
    parts, i, n, start = [], 0, len(sql), 0
    while i < n:
        c = sql[i]
        if c in "'\"`":
            if i > start:
                parts.append(("code", sql[start:i]))
            j = i + 1
            while j < n:
                if sql[j] == "\\" and c != "`":
                    j += 2
                    continue
                if sql[j] == c:
                    if j + 1 < n and sql[j + 1] == c:
                        j += 2
                        continue
                    break
                j += 1
            parts.append(("text", sql[i:j + 1]))
            i = start = j + 1
        elif sql.startswith("--", i):
            if i > start:
                parts.append(("code", sql[start:i]))
            j = sql.find("\n", i)
            j = n if j < 0 else j
            parts.append(("comment", sql[i:j]))
            i = start = j
        elif c == ";":
            if i > start:
                parts.append(("code", sql[start:i]))
            parts.append(("end", ";"))
            i = start = i + 1
        else:
            i += 1
    if start < n:
        parts.append(("code", sql[start:]))
    return parts


def _qualify_parts(parts):
    return [(k, _NAME_RE.sub(lambda m: f"{CATALOG}.{SCHEMA}.{m.group(1)}", t) if k == "code" else t) for k, t in parts]


def qualify(sql):
    """SQL 中のハンズオンのテーブル・View・関数名に「カタログ.スキーマ.」を付ける。"""
    return "".join(t for _, t in _qualify_parts(_lex(sql)))


def run_sql(sql, args=None):
    """セミコロン区切りの SQL を、名前を完全修飾してから順に実行し、最後の結果を表示する。"""
    statements, current, has_code = [], [], False
    for kind, text in _qualify_parts(_lex(sql)) + [("end", ";")]:
        if kind == "end":
            if has_code:
                statements.append("".join(current).strip())
            current, has_code = [], False
        else:
            current.append(text)
            has_code = has_code or (kind != "comment" and text.strip() != "")
    df = None
    for stmt in statements:
        if re.fullmatch(r"(?is)(--[^\n]*\n|\s)*SHOW\s+(TABLES|USER\s+FUNCTIONS)\s*", stmt):
            stmt = f"{stmt} IN {CATALOG}.{SCHEMA}"
        df = spark.sql(stmt, args=args) if args else spark.sql(stmt)
    if df is not None and df.columns:
        display(df)
    return df


print(f"✅ 使用するスキーマ: {FQ_SCHEMA}（SQL は run_sql() で、名前にこのカタログ・スキーマを付けて実行します）")
