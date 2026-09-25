# Databricks notebook source
# MAGIC %md
# MAGIC # 00_config：ハンズオン共通設定
# MAGIC
# MAGIC 各ノートブックの先頭セル `%run ./00_config` から読み込まれ、次を行います。
# MAGIC
# MAGIC 1. カタログ・スキーマ名を決める（下の `CONFIG` を編集）
# MAGIC 2. スキーマが無ければ作成する
# MAGIC 3. `USE CATALOG` / `USE SCHEMA` を実行する（以降の `%sql` セルはこのスキーマで動く）
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

print(f"✅ 使用するスキーマ: {FQ_SCHEMA}")
