# Databricks notebook source
# MAGIC %md
# MAGIC # 10_session2_catchup：第2回の準備（第1回の結果を再現する）
# MAGIC
# MAGIC 第1回を欠席した方、第1回と別のスキーマで第2回を行う方、第1回のデータを消してしまった方は、第2回の最初にこのノートブックを「すべて実行」してください（数分かかります）。
# MAGIC
# MAGIC 第1回の Exercise のうち、データを作るもの（00 → 02 → 05 → 06）を順に実行します。Exercise 1・3・4 は画面操作と確認だけなので実行しません。
# MAGIC 実行後は、第1回の最後と同じ状態（A014 承認済み）になります。

# COMMAND ----------

# MAGIC %run ./00_setup_tables_and_data

# COMMAND ----------

# MAGIC %run ./02_ex2_mapping_and_views

# COMMAND ----------

# MAGIC %run ./05_ex5_review_queue

# COMMAND ----------

# MAGIC %run ./06_ex6_data_quality

# COMMAND ----------

print(f"✅ 第1回の結果を {FQ_SCHEMA} に再現しました。第2回は 05b_ex5b_evidence_candidates から始めてください。")
