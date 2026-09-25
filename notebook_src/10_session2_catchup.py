# Databricks notebook source
# MAGIC %md
# MAGIC # 10_session2_catchup：第2回の準備（第1回の結果を再現する）
# MAGIC
# MAGIC 第1回を欠席した方、第1回と別のスキーマで第2回を行う方、第1回のデータを消してしまった方は、第2回の最初にこのノートブックを「すべて実行」してください（数分かかります）。
# MAGIC
# MAGIC 第1回の Exercise のうち、データを作るもの（00 → 02 → 05 → 06）を順に実行します。Exercise 1・3・4 は画面操作と確認だけなので実行しません。
# MAGIC 実行後は、第1回の最後と同じ状態（A014 承認済み）になります。

# COMMAND ----------

# MAGIC %md
# MAGIC **第1回の Exercise 0：テーブルと初期データを作る**
# MAGIC
# MAGIC > **💡 解説**
# MAGIC > - **仕組み**：`%run` は、指定したノートブックを、このノートブックと同じ実行環境で上から順に実行します。呼び出したノートブックの中の `%run ./00_config` も実行されるので、同じ設定が使われます。
# MAGIC > - **利点**：第1回の手順を書き写さなくても、第1回と同じ SQL をそのまま再実行して、同じ状態を再現できます。

# COMMAND ----------

# MAGIC %run ./00_setup_tables_and_data

# COMMAND ----------

# MAGIC %md
# MAGIC **第1回の Exercise 2：Excel の履歴の取り込み、共通機種IDへの変換、採算 View の作成**
# MAGIC
# MAGIC > **💡 解説**
# MAGIC > - **補足**：Volume に Excel が無い場合は、ノートブックの近く（Git フォルダの `data/` など）にある Excel を自動でコピーします。見つからない場合は、ここで止まってアップロードの方法を表示します。

# COMMAND ----------

# MAGIC %run ./02_ex2_mapping_and_views

# COMMAND ----------

# MAGIC %md
# MAGIC **第1回の Exercise 5：レビューキューの作成と、JP-A11-SE の承認**
# MAGIC
# MAGIC > **💡 解説**
# MAGIC > - **なぜ**：第2回の Exercise 5B・8 は、第1回で JP-A11-SE を承認した後の状態を前提にしています。

# COMMAND ----------

# MAGIC %run ./05_ex5_review_queue

# COMMAND ----------

# MAGIC %md
# MAGIC **第1回の Exercise 6：品質ルールのサマリの作成**
# MAGIC
# MAGIC > **💡 解説**
# MAGIC > - **補足**：わざと失敗させるセル（CHECK 制約）は、エラーを表示して次へ進むので、ここで止まることはありません。

# COMMAND ----------

# MAGIC %run ./06_ex6_data_quality

# COMMAND ----------

# MAGIC %md
# MAGIC **完了の確認**
# MAGIC
# MAGIC > **💡 解説**
# MAGIC > - **なぜ**：どのスキーマに再現したかを表示します。第2回は、同じ 00_config の設定のまま 05b から進めます。

# COMMAND ----------

print(f"✅ 第1回の結果を {FQ_SCHEMA} に再現しました。第2回は 05b_ex5b_evidence_candidates から始めてください。")
