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

# MAGIC %md
# MAGIC ### ダッシュボードの定義を読み込み、データセットを検証する
# MAGIC
# MAGIC > **💡 解説**
# MAGIC > - **なぜ**：ダッシュボードの中の SQL が1つでも失敗すると、画面にエラーが出ます。配置する前に、すべてのデータセットの SQL を実行して確かめます。
# MAGIC > - **仕組み**：ダッシュボードの定義（JSON）の `__FQ__` を、00_config のカタログ・スキーマに置き換えます。そのうえで、わざと別のスキーマ（`information_schema`）に切り替えてから各 SQL を実行します。ダッシュボードは `USE` なしで実行されるので、名前が完全な形になっていないと、ここで失敗して気づけます。
# MAGIC > - **利点**：ダッシュボードの定義を JSON としてファイルで管理できるので、Git で変更を追えます。環境（カタログ・スキーマ）が違っても、同じ定義を使い回せます。

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

# MAGIC %md
# MAGIC ### ダッシュボードを作成（または更新）して公開する
# MAGIC
# MAGIC > **💡 解説**
# MAGIC > - **仕組み**：Databricks SDK の `WorkspaceClient` は、ノートブックの実行者の権限で REST API を呼び出します。同じ名前のダッシュボードがあれば更新（PATCH）、無ければ作成（POST）し、最後に公開（published）します。`embed_credentials: True` で、公開したダッシュボードは作成者の権限でデータを読みます。
# MAGIC > - **利点**：何度実行しても、ダッシュボードは1つのまま最新の定義に更新され、URL も変わりません。講師の事前準備やジョブによる自動化にも、そのまま使えます。
# MAGIC > - **補足**：SQL Warehouse は 00_config の `warehouse_id` を使います。空の場合は、起動中の Warehouse、無ければ最初の Warehouse を自動で選びます（Free Edition では、既定の Warehouse が1つだけあります）。

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
