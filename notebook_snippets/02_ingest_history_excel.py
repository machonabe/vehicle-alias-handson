# Databricks notebook source
# MAGIC %md
# MAGIC ## 2-0. 過去の人手承認履歴（Excel）を Volume に置いて取り込む
# MAGIC
# MAGIC 各部署が過去に人手で作った対応表（Excel）を、Unity Catalog の **Volume** に置き、Delta テーブル `alias_mapping_history` として取り込みます。後の 2-3・2-4 で、この履歴を名称の照合と対応表への取り込みに使います。
# MAGIC
# MAGIC > **💡 解説**
# MAGIC > - **なぜ**：属人的な Excel は、共有フォルダやメールに散らばり、「どれが最新か」「誰が見てよいか」が分からなくなりがちです。まず Unity Catalog の管理下に置くことで、置き場所・権限・履歴を1か所にそろえます。
# MAGIC > - **仕組み**：Volume は、テーブルにする前のファイル（Excel・CSV・PDF など）を置くための、Unity Catalog の保存場所です。`/Volumes/<カタログ>/<スキーマ>/<Volume名>/` というパスでアクセスでき、テーブルと同じように `GRANT` で権限を付けられます。
# MAGIC > - **利点**：元の Excel をそのまま残したまま、取り込んだテーブルに「どのファイルから・いつ取り込んだか」を記録できます。元ファイルと取り込み結果の対応を後から確認できるので、監査や問い合わせに答えやすくなります。

# COMMAND ----------

# MAGIC %md
# MAGIC ### 2-0-1. 取り込み用の Volume を作る
# MAGIC
# MAGIC > **💡 解説**
# MAGIC > - **仕組み**：`CREATE VOLUME` は、`00_config` のスキーマの下に Volume `handson_files` を作ります（`run_sql()` が名前にカタログ・スキーマを付けます）。ストレージの場所を指定しない **マネージド Volume** なので、保存先のクラウドストレージは Unity Catalog が管理します。
# MAGIC > - **利点**：ストレージのパスや認証情報を参加者が意識する必要がありません。Free Edition でもそのまま作れます。

# COMMAND ----------

run_sql("""
CREATE VOLUME IF NOT EXISTS handson_files
COMMENT 'ハンズオン用の元ファイル置き場（人手で作成した対応履歴の Excel など・架空データ）'
""")
VOLUME_DIR = f"/Volumes/{CATALOG}/{SCHEMA}/handson_files"
EXCEL_NAME = "alias_mapping_history.xlsx"
EXCEL_PATH = f"{VOLUME_DIR}/{EXCEL_NAME}"
print("Volume:", VOLUME_DIR)

# COMMAND ----------

# MAGIC %md
# MAGIC ### 2-0-2. Excel を Volume に置く
# MAGIC
# MAGIC **画面から置く場合（体験としておすすめ）：**
# MAGIC 1. GitHub のリポジトリから `data/alias_mapping_history.xlsx` をダウンロードします（Git フォルダで取り込んだ場合は、ワークスペースの `data/` フォルダにあります）。
# MAGIC 2. 左のサイドバーの **カタログ** → `00_config` のカタログ → スキーマ → **ボリューム** → `handson_files` を開きます。
# MAGIC 3. **このボリュームにアップロード** をクリックし、Excel を選んでアップロードします。
# MAGIC
# MAGIC 下のセルは、Volume に Excel が無い場合に、ノートブックの近く（Git フォルダの `data/` など）にある Excel を自動でコピーします。どちらにも無い場合は、アップロード方法を表示して止まります。
# MAGIC
# MAGIC > **💡 解説**
# MAGIC > - **仕組み**：サーバーレスのノートブックからは、Volume が `/Volumes/...` という普通のファイルパスとして見えます。そのため、Python の `shutil` や `open()` でそのまま読み書きできます。ワークスペースのファイル（Git フォルダ内の `data/` など）も `/Workspace/...` で読めます。
# MAGIC > - **利点**：Volume に置いた後は、ノートブック・SQL（`read_files`）・ジョブ・パイプラインのどれからでも、同じパスで同じファイルを読めます。

# COMMAND ----------

import os
import posixpath
import shutil

if os.path.exists(EXCEL_PATH):
    print("✅ Volume に Excel があります:", EXCEL_PATH)
else:
    notebook_dir = "/Workspace" + posixpath.dirname(
        dbutils.notebook.entry_point.getDbutils().notebook().getContext().notebookPath().get())
    candidates = [posixpath.normpath(posixpath.join(notebook_dir, rel, EXCEL_NAME)) for rel in ("../data", "data", ".")]
    found = next((c for c in candidates if os.path.exists(c)), None)
    if found is None:
        raise FileNotFoundError(
            f"Volume に Excel がありません。{EXCEL_NAME} を {VOLUME_DIR} にアップロードしてから、このセルを再実行してください。\n"
            f"（Excel は GitHub の data/{EXCEL_NAME} にあります。探した場所: {candidates}）")
    shutil.copyfile(found, EXCEL_PATH)
    print(f"✅ {found} を Volume にコピーしました:", EXCEL_PATH)

display(dbutils.fs.ls(VOLUME_DIR))

# COMMAND ----------

# MAGIC %md
# MAGIC ### 2-0-3. Excel を読み、列名と型をそろえる
# MAGIC
# MAGIC Excel のシート「対応履歴」は、1〜2行目が表題と注記、**3行目が見出し**、4行目以降がデータです。日本語の見出しをテーブルの列名（英語）に対応づけ、空欄は NULL、日付は日付型にそろえます。
# MAGIC
# MAGIC > **💡 解説**
# MAGIC > - **なぜ**：人が作った Excel は、表題行・結合セル・空欄・日付の書式などが混ざっていて、そのままではテーブルになりません。取り込みの時点で「見出しは何行目か」「どの列をどの列名にするか」を**コードで明示**しておけば、毎回同じ結果になります。
# MAGIC > - **仕組み**：`openpyxl` で Excel を読み込みます（サーバーレスに入っていない場合は、このセルでインストールします）。`data_only=True` を指定すると、数式ではなく計算済みの値を読みます。見出しの対応表 `COLUMN_MAP` に無い列は無視し、必要な見出しが欠けていればエラーで止めます。
# MAGIC > - **利点**：Excel の列の並び替えや、余計な列の追加があっても取り込みが壊れにくくなります。必要な列が消えた場合は、黙って誤ったデータを作らずにエラーで気づけます。
# MAGIC > - **補足**：この程度の件数（数十〜数千行）なら、この方法で十分です。大量のファイルを定期的に取り込む場合は、Auto Loader や Lakeflow のパイプラインで、Volume に置かれたファイルを自動で取り込む形にします。

# COMMAND ----------

import datetime as dt

try:
    import openpyxl
except ImportError:
    import subprocess
    import sys
    subprocess.check_call([sys.executable, "-m", "pip", "install", "-q", "openpyxl"])
    import openpyxl

SHEET_NAME = "対応履歴"
HEADER_ROW = 3   # 見出しの行（1行目が表題、2行目が注記）
COLUMN_MAP = {   # Excel の見出し → テーブルの列名
    "履歴ID": "history_id", "元システム": "source_system", "国": "country", "業務領域": "business_area",
    "元の名称": "source_name", "元のコード": "source_code", "対応づけた共通機種ID": "mapped_vehicle_id",
    "適用開始日": "valid_from", "適用終了日": "valid_to", "状態": "history_status",
    "承認部署": "approved_by", "承認日": "approved_at", "元資料": "source_document",
}
DATE_COLUMNS = {"valid_from", "valid_to", "approved_at"}


def to_date(value):
    if value is None or (isinstance(value, str) and not value.strip()):
        return None
    if isinstance(value, dt.datetime):
        return value.date()
    if isinstance(value, dt.date):
        return value
    return dt.datetime.strptime(str(value).strip().replace("/", "-"), "%Y-%m-%d").date()


def to_text(value):
    if value is None:
        return None
    text = str(value).strip()
    return text or None


workbook = openpyxl.load_workbook(EXCEL_PATH, read_only=True, data_only=True)
rows = list(workbook[SHEET_NAME].iter_rows(values_only=True))
header = [to_text(h) for h in rows[HEADER_ROW - 1]]
missing = [h for h in COLUMN_MAP if h not in header]
if missing:
    raise ValueError(f"Excel に必要な見出しがありません: {missing}（見出しは {HEADER_ROW} 行目の想定）")

records = []
for row in rows[HEADER_ROW:]:
    if all(v is None for v in row):
        continue   # 空行は読み飛ばす
    values = {COLUMN_MAP[h]: v for h, v in zip(header, row) if h in COLUMN_MAP}
    records.append({col: (to_date(v) if col in DATE_COLUMNS else to_text(v)) for col, v in values.items()})

print(f"✅ {len(records)} 行を読み込みました（シート「{SHEET_NAME}」、見出しは {HEADER_ROW} 行目）")
for r in records:
    print(r["history_id"], r["source_name"], r["source_code"], r["mapped_vehicle_id"], r["history_status"])

# COMMAND ----------

# MAGIC %md
# MAGIC ### 2-0-4. Delta テーブルとして保存する
# MAGIC
# MAGIC 読み込んだ行を Delta テーブル `alias_mapping_history` に保存します。取り込み元のファイルと取り込み日時も列として残します。
# MAGIC
# MAGIC > **💡 解説**
# MAGIC > - **なぜ**：Excel のままでは、SQL で他のテーブルと結合したり、Genie から参照したりできません。Delta テーブルにすると、対応表・実績データと同じように扱えます。
# MAGIC > - **仕組み**：列の型をスキーマ（`StructType`）で明示してから DataFrame を作り、`saveAsTable` で保存します。`mode("overwrite")` なので、Excel を差し替えて再実行すると、テーブルも最新の内容に置き換わります。`source_file`・`ingested_at` 列に取り込み元と日時を残します。
# MAGIC > - **利点**：Delta はテーブルの変更履歴を持つので、「いつの Excel を取り込んだ結果か」を `DESCRIBE HISTORY` やタイムトラベル（`VERSION AS OF`）で後から確認できます。元の Excel も Volume に残っているので、取り込み結果と元ファイルを突き合わせられます。

# COMMAND ----------

from pyspark.sql import functions as F
from pyspark.sql import types as T

HISTORY_SCHEMA = T.StructType([
    T.StructField("history_id", T.StringType(), False),
    T.StructField("source_system", T.StringType()),
    T.StructField("country", T.StringType()),
    T.StructField("business_area", T.StringType()),
    T.StructField("source_name", T.StringType()),
    T.StructField("source_code", T.StringType()),
    T.StructField("mapped_vehicle_id", T.StringType()),
    T.StructField("valid_from", T.DateType()),
    T.StructField("valid_to", T.DateType()),
    T.StructField("history_status", T.StringType()),
    T.StructField("approved_by", T.StringType()),
    T.StructField("approved_at", T.DateType()),
    T.StructField("source_document", T.StringType()),
])

history_df = (spark.createDataFrame([tuple(r[f.name] for f in HISTORY_SCHEMA.fields) for r in records], HISTORY_SCHEMA)
              .withColumn("source_file", F.lit(EXCEL_PATH))
              .withColumn("ingested_at", F.current_timestamp()))
(history_df.write.mode("overwrite").option("overwriteSchema", "true")
 .saveAsTable(f"{CATALOG}.{SCHEMA}.alias_mapping_history"))

run_sql("""
COMMENT ON TABLE alias_mapping_history IS '過去の人手対応履歴（架空）。Volume の Excel（source_file）から取り込んだもの。一部のみ存在し、名称だけのものもある。確定マスタではない。';
ALTER TABLE alias_mapping_history SET TAGS ('handson_business_domain' = 'Vehicle Profitability', 'data_role' = 'mapping_history');
SELECT history_id, source_name, source_code, mapped_vehicle_id, valid_from, valid_to, history_status, source_file, ingested_at
FROM alias_mapping_history
ORDER BY history_id
""")
