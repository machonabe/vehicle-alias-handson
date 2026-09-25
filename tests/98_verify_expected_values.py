# Databricks notebook source
# MAGIC %md
# MAGIC # 98_verify_expected_values：期待値チェック（講師用）
# MAGIC
# MAGIC 第1回（`00_setup` → `01` → `02` → `05` → `06`）と第2回（`05b` → `07` → `08` → `08b` → `08c`）をすべて実行した後に実行します。
# MAGIC ガイドに書いた期待値と、実際の結果が一致するかを確認します（A014 を Exercise 5 で、A018〈TH-Z999〉を Exercise 8 で承認した後の状態）。

# COMMAND ----------

# MAGIC %run ./00_config

# COMMAND ----------

def q(sql):
    """00_config の qualify() で名前を完全修飾してから実行する。"""
    return spark.sql(qualify(sql))


def one(sql):
    return q(sql).collect()[0]


checks = []


def check(name, actual, expected):
    ok = actual == expected
    checks.append((name, ok))
    print(("✅" if ok else "❌"), name, "| 実際:", actual, "| 期待:", expected)


# 件数（vehicle_alias_master は 2-4 の MERGE で 1 行、5B-6 の MERGE で 2 行増える）
for table, n in [("canonical_vehicle", 4), ("vehicle_alias_master", 22), ("alias_mapping_history", 5),
                 ("development_plan", 9), ("sales_actual", 26), ("production_actual", 11), ("vehicle_bom", 12)]:
    check(f"件数 {table}", one(f"SELECT count(*) AS n FROM {table}").n, n)

# Exercise 2 / 4：VEHICLE-001 の採算
r = one("""SELECT sum(planned_material_cost) AS plan, sum(actual_material_cost) AS actual,
                  sum(material_cost_variance) AS var, sum(planned_sales) AS plan_sales
           FROM v_vehicle_monthly_profitability WHERE canonical_vehicle_id = 'VEHICLE-001'""")
check("計画材料費 合計", float(r.plan), 39060.0)
check("実績材料費 合計", float(r.actual), 38730.0)
check("材料費差額 合計", float(r.var), -330.0)
check("計画売上 合計", float(r.plan_sales), 65100.0)

r = one("""SELECT CAST(month AS STRING) AS m, material_cost_variance AS v FROM v_vehicle_monthly_profitability
           WHERE canonical_vehicle_id = 'VEHICLE-001' ORDER BY abs(material_cost_variance) DESC LIMIT 1""")
check("材料費差額が最大の月", (r.m, float(r.v)), ("2025-08-01", 490.0))

r = one("""SELECT CAST(month AS STRING) AS m, sales_variance AS v FROM v_vehicle_monthly_profitability
           WHERE canonical_vehicle_id = 'VEHICLE-001' ORDER BY abs(sales_variance) DESC LIMIT 1""")
check("売上差額が最大の月", (r.m, float(r.v)), ("2025-04-01", -1160.0))

# Exercise 5：A014 承認後の 2025-09 販売
r = one("""SELECT sales_volume, actual_sales FROM v_vehicle_monthly_profitability
           WHERE canonical_vehicle_id = 'VEHICLE-001' AND month = DATE'2025-09-01'""")
check("2025-09 販売台数（承認後）", r.sales_volume, 3590)
check("2025-09 実績売上（承認後）", float(r.actual_sales), 10862.0)

# 世代・派生車が混ざっていないこと
check("JP-A10 は VEHICLE-002",
      one("SELECT canonical_vehicle_id AS v FROM v_sales_resolved WHERE sales_vehicle_code = 'JP-A10'").v, "VEHICLE-002")
check("JP-A11E は VEHICLE-003",
      one("SELECT max(canonical_vehicle_id) AS v FROM v_sales_resolved WHERE sales_vehicle_code = 'JP-A11E'").v, "VEHICLE-003")

# Exercise 5 / 5B：レビューキュー（A014 承認後、根拠による候補化の後）
queue = {row.source_code: row.review_category for row in q("SELECT source_code, review_category FROM v_alias_review_queue").collect()}
check("レビューキュー（TH-Z999 は Exercise 8 で承認済み）", queue, {
    "MTO-988": "要確認", "CN-X12": "要確認（複数候補）", "MTO-990": "要確認（確定マスタの矛盾）",
    "KR-Q777": "未解決"})

# Exercise 5B：根拠とスコア
check("根拠の件数", one("SELECT count(*) AS n FROM alias_evidence").n, 7)
scores = {(r.source_code, r.candidate_vehicle_id): r.evidence_score
          for r in q("SELECT source_code, candidate_vehicle_id, evidence_score FROM v_evidence_score").collect()}
check("根拠スコア", scores, {("TH-Z999", "VEHICLE-001"): 88, ("KR-Q777", "VEHICLE-001"): 40, ("KR-Q777", "VEHICLE-004"): 8})
check("TH-Z999 承認後の 2025-07 販売台数",
      one("""SELECT sales_volume AS v FROM v_vehicle_monthly_profitability
             WHERE canonical_vehicle_id = 'VEHICLE-001' AND month = DATE'2025-07-01'""").v, 3340)

# Exercise 6：品質ルール
dq = {row.rule_id: row.violations for row in q("SELECT rule_id, violations FROM v_dq_summary").collect()}
check("DQ サマリ", dq, {"DQ-1": 1, "DQ-2": 2, "DQ-3": 1, "DQ-4": 1, "DQ-5": 4})
check("タイヤ本数 MTO-987",
      one("SELECT sum(quantity_per_vehicle) AS q FROM vehicle_bom WHERE mto_code = 'MTO-987' AND part_category = 'TIRE'").q, 6)

# Exercise 7：効果試算（仮説値）
r = one("SELECT sum(current_hours) AS c, sum(target_hours) AS t FROM effort_estimate")
check("効果試算 現状/導入後", (r.c, r.t), (100.0, 32.0))

# Exercise 8：Metric View と元の View が同じ数字を返すこと
mv = one("""SELECT MEASURE(`実績材料費`) AS cost, MEASURE(`実績売上`) AS sales, MEASURE(`販売台数`) AS vol
            FROM mv_vehicle_profitability WHERE `共通機種ID` = 'VEHICLE-001'""")
v = one("""SELECT sum(actual_material_cost) AS cost, sum(actual_sales) AS sales, sum(sales_volume) AS vol
           FROM v_vehicle_monthly_profitability WHERE canonical_vehicle_id = 'VEHICLE-001'""")
check("Metric View と View の一致（材料費・売上・台数）", (float(mv.cost), float(mv.sales), mv.vol), (float(v.cost), float(v.sales), v.vol))
check("実績売上（TH-Z999 承認後）", float(mv.sales), 59674.0)
r = one("""SELECT MEASURE(`1台あたり計画限界利益（簡易）`) AS p FROM mv_vehicle_profitability
           WHERE `共通機種ID` = 'VEHICLE-001' AND `月` = DATE'2025-04-01'""")
check("2025-04 の1台あたり計画限界利益（簡易）", round(float(r.p), 3), 1.2)

# Exercise 8：データ信頼度と打ち手
t = one("SELECT * FROM v_data_trust_summary")
check("データ信頼度の判定", t.trust_level, "要注意（重要な品質ルール違反あり）")
check("集計に入っていない売上", float(t.unresolved_sales_amount), 344.0)
check("承認待ちの候補", t.pending_candidates, 5)
acts = {r.category: r.n for r in q("SELECT category, count(*) AS n FROM v_exec_action_items GROUP BY category").collect()}
check("打ち手の一覧", acts, {"材料費の計画超過": 2, "コード未確定：要確認": 1, "コード未確定：要確認（複数候補）": 1,
                        "コード未確定：要確認（確定マスタの矛盾）": 1, "コード未確定：未解決": 1, "品質ルール違反": 3})

failed = [n for n, ok in checks if not ok]
print(f"\n{len(checks) - len(failed)} / {len(checks)} 件 OK")
assert not failed, f"期待値と異なる項目: {failed}"
