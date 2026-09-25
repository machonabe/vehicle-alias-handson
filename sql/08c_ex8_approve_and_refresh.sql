-- =====================================================================
-- 08c_ex8_approve_and_refresh.sql  Exercise 8-6：データ整備が経営ダッシュボードに反映されることを確認する（第2回・5分）
-- 前提 : 08b でダッシュボードを配置し、画面を開いていること
-- 流れ : マスタ管理担当が TH-Z999 の根拠（Exercise 5B で 88 点）を確認して承認する
--        → ダッシュボードを再読み込みすると、売上・データ信頼度・打ち手の一覧が変わる
-- =====================================================================
-- 💡 なぜ：マスタ管理担当の1回の承認が、経営者の画面にそのまま反映されることを確かめます。
-- @config-begin  ノートブック版では 00_config がカタログ・スキーマを設定するため、この範囲は自動で除去されます
USE CATALOG workspace;             -- ★ SQL エディタで実行する場合は config/00_config と同じ値にする
USE SCHEMA vehicle_alias_handson;  -- ★ 同上
-- @config-end

-- 8-6-1. 承認前の数字を控える
-- 💡 なぜ：承認の前後で比べるため、今の数字を控えます。
SELECT 'before' AS timing, unresolved_sales_amount, sales_amount_coverage, pending_candidates, trust_level
FROM v_data_trust_summary;

-- 8-6-2. 担当者が根拠を確認して承認する（役割名で記録。根拠は alias_evidence）
-- 💡 仕組み：対応表の1行を APPROVED に更新するだけです。
-- 💡 利点：再集計やダッシュボードの作り直しは不要です。
UPDATE vehicle_alias_master
SET approval_status = 'APPROVED',
    mapping_method  = 'HUMAN_REVIEWED',
    approved_by     = 'タイ営業企画 マスタ管理担当（架空）',
    source_document = 'alias_evidence（出荷実績・原価シート・担当者メモ・クエリ履歴）',
    remarks         = concat(coalesce(remarks, ''), ' / 根拠を確認して承認'),
    updated_at      = current_timestamp()
WHERE alias_id = 'A018';

-- 8-6-3. 承認後の数字（View は自動で最新の対応を反映する。再集計の作業は不要）
-- 💡 なぜ：View と Metric View は参照のたびに計算し直すので、承認の結果がすぐに反映されることを確かめます。
SELECT 'after' AS timing, unresolved_sales_amount, sales_amount_coverage, pending_candidates, trust_level
FROM v_data_trust_summary;

-- 💡 なぜ：共通機種 VEHICLE-001 の売上と台数が、承認した分だけ増えたことを確かめます。
SELECT MEASURE(`実績売上`) AS actual_sales, MEASURE(`販売台数`) AS sales_volume
FROM mv_vehicle_profitability
WHERE `共通機種ID` = 'VEHICLE-001';
-- 期待値: 未変換の売上が 150 百万円減り、VEHICLE-001 の販売台数が 60 台増える（TH-Z999 の 2025-07 分）

-- 8-6-4. ダッシュボードをブラウザで再読み込みして、KPI・データ信頼度・打ち手の一覧が変わったことを確認する
