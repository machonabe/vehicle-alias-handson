-- =====================================================================
-- 05_ex5_review_queue.sql  Exercise 5：曖昧・未解決データを扱う（15分）
-- 方針 : AI・ルールによる候補（CANDIDATE）は確定マスタではない。
--        人が承認して APPROVED になった対応だけが集計に使われる。
--   95点以上   : 自動承認候補（ワンクリック承認の対象。ただし承認操作と記録は必須）
--   70〜94点   : 人による確認
--   70点未満   : 未解決
--   候補が複数 : 点数に関わらず人による確認（70点未満のみなら未解決）
--   マスタ矛盾 : 人による確認（確定済み対応の修正が必要）
-- =====================================================================
-- 💡 なぜ：自動で決められないデータを、信頼度に応じて「承認候補・要確認・未解決」に分け、人の判断を効率よく回します。
-- 💡 仕組み：AI やルールによる候補は CANDIDATE として持ち、人が承認して初めて APPROVED になります。
-- @config-begin  ノートブック版では 00_config がカタログ・スキーマを設定するため、この範囲は自動で除去されます
USE CATALOG workspace;             -- ★ SQL エディタで実行する場合は config/00_config と同じ値にする
USE SCHEMA vehicle_alias_handson;  -- ★ 同上
-- @config-end

-- ---------------------------------------------------------------------
-- 5-1. レビューキュー View：未解決レコードごとに候補と信頼度を並べ、分類する
-- ---------------------------------------------------------------------
-- 💡 なぜ：未解決のコードごとに、候補・スコア・影響額を1行にまとめ、担当者が優先順位をつけて確認できるようにします。
-- 💡 仕組み：候補は `named_struct`（名前付きの構造体）の配列にまとめ、`array_sort` とラムダ式 `(l, r) -> r.score - l.score` でスコアの高い順に並べます。分類は CASE 式の順番で決まり、「マスタの矛盾」「候補なし」「70点未満」「複数候補」を先に判定します。
-- 💡 利点：分類のルールが SQL として明示されるので、なぜその分類になったかを誰でも確認できます。
CREATE OR REPLACE VIEW v_alias_review_queue
COMMENT '共通機種IDに変換できなかったコードの確認キュー。AI候補は判断支援であり確定ではない。'
AS
WITH unresolved AS (
  SELECT business_area, country, source_code, norm_code(source_code) AS norm_source_code,
         any_value(resolution_status) AS resolution_status,
         min(month) AS first_month, max(month) AS last_month,
         count(*) AS record_count, sum(volume) AS affected_volume,
         sum(amount) AS affected_amount, any_value(amount_type) AS amount_type
  FROM v_unresolved_records
  GROUP BY business_area, country, source_code
), candidates AS (
  SELECT business_area, norm_code(local_vehicle_code) AS norm_code_, country,
         alias_id, canonical_vehicle_id, confidence_score, remarks
  FROM vehicle_alias_master
  WHERE approval_status = 'CANDIDATE'
), joined AS (
  SELECT u.*,
         count(c.alias_id)        AS candidate_count,
         max(c.confidence_score)  AS top_score,
         array_sort(collect_list(
           CASE WHEN c.alias_id IS NOT NULL THEN
             named_struct('score', c.confidence_score, 'vehicle', c.canonical_vehicle_id,
                          'alias_id', c.alias_id, 'reason', c.remarks) END),
           (l, r) -> r.score - l.score)  AS candidate_list
  FROM unresolved u
  LEFT JOIN candidates c
    ON c.business_area = u.business_area
   AND c.norm_code_    = u.norm_source_code
   AND (c.country = u.country OR u.business_area <> 'SALES')
  GROUP BY ALL
)
SELECT
  business_area, country, source_code, resolution_status,
  first_month, last_month, record_count, affected_volume, affected_amount, amount_type,
  candidate_count, top_score, candidate_list,
  CASE
    WHEN resolution_status = 'CONFLICT' THEN '要確認（確定マスタの矛盾）'
    WHEN candidate_count = 0            THEN '未解決（候補なし）'
    WHEN top_score < 70                 THEN '未解決'
    WHEN candidate_count > 1            THEN '要確認（複数候補）'
    WHEN top_score >= 95                THEN '自動承認候補'
    ELSE                                     '要確認'
  END AS review_category
FROM joined;

-- 💡 なぜ：分類の結果を、確認の優先順に並べて見ます。
SELECT review_category, business_area, source_code, top_score, candidate_count,
       affected_volume, affected_amount, amount_type, candidate_list
FROM v_alias_review_queue
ORDER BY CASE review_category WHEN '自動承認候補' THEN 1 WHEN '要確認' THEN 2
                              WHEN '要確認（複数候補）' THEN 3 WHEN '要確認（確定マスタの矛盾）' THEN 4 ELSE 5 END,
         source_code;
-- 期待値:
--   自動承認候補               : JP-A11-SE（96）
--   要確認                     : MTO-988（91）
--   要確認（複数候補）         : CN-X12（82: VEHICLE-001 / 78: VEHICLE-004）
--   要確認（確定マスタの矛盾） : MTO-990
--   未解決                     : TH-Z999（45）
--   未解決（候補なし）         : KR-Q777

-- 5-2. 分類ごとの影響（集計から除外されている台数・金額）
-- 💡 なぜ：分類ごとに、集計から外れている台数と金額を示します。影響の大きいものから確認できます。
SELECT review_category, amount_type,
       count(*) AS codes, sum(affected_volume) AS volume, sum(affected_amount) AS amount_million_jpy
FROM v_alias_review_queue
GROUP BY ALL
ORDER BY review_category;

-- ---------------------------------------------------------------------
-- 5-3. 担当者の判断を記録する（ここでは講師の指示で JP-A11-SE を承認する例）
--       ※ 実務では承認者・承認日時・根拠資料を必ず残す。個人名ではなく役割名で記録する例にしている。
-- ---------------------------------------------------------------------
-- 💡 なぜ：担当者の判断を、承認者（役割名）と根拠資料とともに記録します。
-- 💡 仕組み：Delta テーブルは UPDATE を直接実行でき、変更はテーブルの履歴に残ります。
-- 💡 利点：確定の操作が1回の更新で済み、その結果は再集計なしで View に反映されます。
UPDATE vehicle_alias_master
SET approval_status = 'APPROVED',
    mapping_method  = 'HUMAN_REVIEWED',
    approved_by     = '商品企画部 マスタ管理担当（架空）',
    source_document = '特別仕様車 追加通知 SE-2025-09（架空）',
    remarks         = concat(coalesce(remarks, ''), ' / 2025-09 ハンズオンで人が承認'),
    updated_at      = current_timestamp()
WHERE alias_id = 'A014';

-- CN-X12 は「VEHICLE-001 が正しい」と担当者が判断した想定（任意）
-- UPDATE vehicle_alias_master SET approval_status = 'APPROVED', mapping_method = 'HUMAN_REVIEWED',
--        approved_by = '中国営業企画 マスタ管理担当（架空）', updated_at = current_timestamp() WHERE alias_id = 'A016';
-- UPDATE vehicle_alias_master SET approval_status = 'REJECTED', updated_at = current_timestamp() WHERE alias_id = 'A017';

-- 5-4. 承認の効果を確認：2025-09 の販売台数が 3,470 → 3,590 台に増える（View は自動で最新化）
-- 💡 なぜ：承認という1回の更新で、採算の数字が変わることを確かめます。View は参照のたびに計算し直すため、再集計の作業はいりません。
SELECT month, sales_volume, actual_sales
FROM v_vehicle_monthly_profitability
WHERE canonical_vehicle_id = 'VEHICLE-001' AND month = DATE'2025-09-01';

-- 5-5. 監査：Delta の履歴で「いつ・誰が・何を変えたか」を確認し、必要なら過去版と比較
-- 💡 なぜ：対応表を「いつ・誰が・どの操作で」変えたかを確かめます。
-- 💡 仕組み：Delta は、テーブルへの変更をトランザクションログに記録しています。`DESCRIBE HISTORY` で、その一覧を見られます。
-- 💡 利点：監査のために別の仕組みを作らなくても、変更の記録が残ります。
DESCRIBE HISTORY vehicle_alias_master;

-- 💡 仕組み：タイムトラベル（`VERSION AS OF`）で、変更前の状態を読み出して比べます。
-- 💡 利点：誤って承認しても、いつの状態に戻せばよいかが分かります。
SELECT alias_id, approval_status, mapping_method, approved_by
FROM vehicle_alias_master VERSION AS OF 1     -- ★ DESCRIBE HISTORY で operation = WRITE（初回INSERT）の version に変更
WHERE alias_id = 'A014';

-- ---------------------------------------------------------------------
-- 5-6. （任意）AI Functions で「候補」を生成する例
--       結果はあくまで候補。vehicle_alias_master に入れる場合も approval_status = 'CANDIDATE' とする。
--       ai_similarity はワークスペースで AI Functions が有効な場合のみ利用可能。
-- ---------------------------------------------------------------------
-- SELECT u.source_code, a.local_vehicle_code, a.canonical_vehicle_id,
--        round(ai_similarity(u.source_code, a.local_vehicle_code) * 100) AS similarity_score
-- FROM (SELECT DISTINCT business_area, source_code FROM v_unresolved_records) u
-- JOIN v_alias_approved a ON a.business_area = u.business_area
-- ORDER BY u.source_code, similarity_score DESC;
