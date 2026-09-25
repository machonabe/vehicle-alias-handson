# Databricks notebook source
# MAGIC %md
# MAGIC # 08b_ex8_deploy_dashboard：経営ダッシュボードを配置する（第2回・Exercise 8-4）
# MAGIC
# MAGIC `00_config` のカタログ・スキーマを使って、AI/BI ダッシュボード「車種別採算 経営サマリ」を作成（2回目以降は更新）し、公開します。
# MAGIC 置き場所は `00_config` の `dashboard_parent_path`（空ならこのノートブックと同じフォルダ）です。Git フォルダから実行する場合は、Git フォルダの外を指定してください。
# MAGIC
# MAGIC - ダッシュボードの定義は GitHub の `dashboard/vehicle_profitability.lvdash.json` と同じものです（下のセルに埋め込み済み）。
# MAGIC - SQL Warehouse は `00_config` の `warehouse_id` を使います。空の場合は、ワークスペースの Warehouse から自動で選びます（Free Edition では既定の Serverless Starter Warehouse）。
# MAGIC - 画面から作る場合は、README の「Exercise 8-4（画面から作る場合）」を参照してください。

# COMMAND ----------

# MAGIC %run ./00_config

# COMMAND ----------

import json
import posixpath

# dashboard/vehicle_profitability.lvdash.json（tools/build_notebooks.py が埋め込む）
DASHBOARD_TEMPLATE = r"""__DASHBOARD_JSON__"""
DISPLAY_NAME = "車種別採算 経営サマリ（ハンズオン）"

serialized = DASHBOARD_TEMPLATE.replace("__FQ__", f"`{CATALOG}`.`{SCHEMA}`")
dashboard = json.loads(serialized)

# ダッシュボードの全データセットを、別スキーマを USE した状態で実行して検証する
# （ダッシュボードは USE なしで実行されるため、完全修飾名だけで動くことを確かめる）
spark.sql(f"USE CATALOG `{CATALOG}`")
spark.sql("USE SCHEMA information_schema")
try:
    for ds in dashboard["datasets"]:
        rows = spark.sql("".join(ds["queryLines"])).count()
        print(f"✅ {ds['displayName']}: {rows} 行")
finally:
    spark.sql(f"USE SCHEMA `{SCHEMA}`")

# COMMAND ----------

from databricks.sdk import WorkspaceClient

w = WorkspaceClient()

# SQL Warehouse：config の指定 → 起動中のもの → 最初のもの
warehouse_id = CONFIG.get("warehouse_id") or ""
if not warehouse_id:
    warehouses = list(w.warehouses.list())
    if not warehouses:
        raise RuntimeError("SQL Warehouse が見つかりません。00_config の warehouse_id を指定してください。")
    running = [wh for wh in warehouses if str(wh.state).endswith("RUNNING")]
    warehouse_id = (running or warehouses)[0].id
print("SQL Warehouse:", warehouse_id)

# 配置先：00_config の dashboard_parent_path。空ならこのノートブックと同じフォルダ
#（Git フォルダの中に置くと未コミットの変更になるため、Git フォルダで使う場合は外のフォルダを指定する）
notebook_path = dbutils.notebook.entry_point.getDbutils().notebook().getContext().notebookPath().get()
parent_path = CONFIG.get("dashboard_parent_path") or posixpath.dirname(notebook_path)
w.workspace.mkdirs(parent_path)
dashboard_path = f"{parent_path}/{DISPLAY_NAME}.lvdash.json"

body = {"display_name": DISPLAY_NAME, "warehouse_id": warehouse_id,
        "serialized_dashboard": json.dumps(dashboard, ensure_ascii=False)}

try:
    dashboard_id = w.workspace.get_status(dashboard_path).resource_id
except Exception:
    dashboard_id = None

if dashboard_id:
    w.api_client.do("PATCH", f"/api/2.0/lakeview/dashboards/{dashboard_id}", body=body)
    print("🔁 既存のダッシュボードを更新しました")
else:
    created = w.api_client.do("POST", "/api/2.0/lakeview/dashboards", body={**body, "parent_path": parent_path})
    dashboard_id = created["dashboard_id"]
    print("🆕 ダッシュボードを作成しました")

w.api_client.do("POST", f"/api/2.0/lakeview/dashboards/{dashboard_id}/published",
                body={"warehouse_id": warehouse_id, "embed_credentials": True})

host = w.config.host.rstrip("/")
DASHBOARD_URL = f"{host}/dashboardsv3/{dashboard_id}/published"
print("✅ 公開しました:", DASHBOARD_URL)
