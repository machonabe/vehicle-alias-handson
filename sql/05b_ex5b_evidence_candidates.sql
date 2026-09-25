-- =====================================================================
-- 05b_ex5b_evidence_candidates.sql  Exercise 5B（発展）：根拠を集めて未解決コードを候補にする（15分）
-- 前提 : Exercise 5（05_ex5_review_queue）を実行済みであること
-- 方針 : 属人的な知識（担当者メモ・ヒアリング）、取引の事実（出荷実績）、過去の資料（原価シート）、
--        利用履歴（クエリ履歴）を「根拠」として Delta に集め、SQL で説明可能なスコアを付ける。
--        スコアが上がっても確定ではない。人が根拠を見て承認するまでは CANDIDATE のまま。
--        集めた根拠は Delta で管理し、Page には「根拠の読み方・判断ルール」と「未確定の情報」だけを書く。
-- =====================================================================
-- 💡 なぜ：属人的な知識や利用の痕跡を「根拠」として集め、未解決のコードを、人が判断しやすい状態にします。
-- 💡 仕組み：根拠の抽出と点数づけは SQL で行い、LLM は使いません。点数が上がっても CANDIDATE のままで、承認は人が行います。
-- @config-begin  ノートブック版では 00_config がカタログ・スキーマを設定するため、この範囲は自動で除去されます
USE CATALOG workspace;             -- ★ SQL エディタで実行する場合は config/00_config と同じ値にする
USE SCHEMA vehicle_alias_handson;  -- ★ 同上
-- @config-end

-- ---------------------------------------------------------------------
-- 5B-1. 根拠の元になるデータ（すべて架空）
-- ---------------------------------------------------------------------
-- (a) 担当者メモ・ヒアリング記録：属人的に管理されていた情報を集めたもの（個人名ではなく役割で記録）
-- 💡 なぜ：担当者の頭の中や手元のメモにある知識を、テーブルとして集めます。誰が言ったかは、個人名ではなく役割で残します。
-- 💡 利点：担当者が異動しても、知識と根拠が残ります。
CREATE OR REPLACE TABLE tacit_knowledge_notes (
  note_id          STRING NOT NULL,
  note_text        STRING COMMENT 'メモ本文（自由記述）',
  source_type      STRING COMMENT '担当者メモ / ヒアリング記録 など',
  recorded_by_role STRING COMMENT '記録者の役割（個人名は入れない）',
  recorded_at      DATE,
  source_document  STRING COMMENT '元資料（架空）'
) COMMENT '属人的に管理されていた対応情報を集約したもの（架空）。確定情報ではない。';

-- 💡 仕組み：メモは自由記述のままです。コードや車両名は、後のステップで SQL で抜き出します。
INSERT INTO tacit_knowledge_notes VALUES
 ('N001','タイ向けの TH-Z999 は Project A11 の暫定コード。発売前から販売システムに仮登録している','担当者メモ'    ,'タイ営業企画（架空）',DATE'2025-07-10','Alpha タイ立上げメモ.xlsx（架空）'),
 ('N002','KR-Q777 は Alpha 11M と同じ仕様のはず。記憶ベースなので要確認'                     ,'ヒアリング記録','生産管理（架空）'    ,DATE'2025-08-05','ヒアリング記録 2025-08（架空）'),
 ('N003','CN-X12 は入力ミスが多いので注意'                                                  ,'担当者メモ'    ,'中国営業企画（架空）',DATE'2025-08-20','中国販売 運用メモ（架空）');

-- (b) 出荷実績：どの MTO がどの国のどの販売コードとして出荷されたか（取引の事実）
-- 💡 なぜ：出荷実績は「この MTO を、この国に、このコードで出荷した」という取引の事実なので、最も強い根拠になります。
CREATE OR REPLACE TABLE shipment_actual (
  shipment_id            STRING NOT NULL,
  mto_code               STRING COMMENT '出荷した MTO コード',
  destination_country    STRING COMMENT '仕向け国',
  destination_model_code STRING COMMENT '仕向け先での販売コード',
  shipped_volume         INT,
  ship_month             DATE
) COMMENT '出荷実績（架空）。MTO と仕向け先の販売コードを結ぶ取引の事実。';

-- 💡 仕組み：SH002 は、既知の対応（MTO-987 → CN-X123）と一致する検算用の行です。
INSERT INTO shipment_actual VALUES
 ('SH001','MTO-987','TH','TH-Z999',  70,DATE'2025-06-01'),
 ('SH002','MTO-987','CN','CN-X123',1300,DATE'2025-07-01');   -- 既知の対応と一致（検算用）

-- (c) 過去の原価積み上げシート：同じ行グループで一緒に合計されていたコード
-- 💡 なぜ：過去の原価シートで同じ行にまとめて合計されていたコードは、当時の担当者が同じ車種として扱っていた手がかりになります。
CREATE OR REPLACE TABLE legacy_cost_sheet_lines (
  sheet_id    STRING COMMENT 'シートID（架空）',
  row_group   STRING COMMENT '同じ車種として合計されていた行グループ',
  source_code STRING COMMENT 'シートに記載されていたコード'
) COMMENT '過去の原価積み上げシートの取込（架空）。同じ行グループのコードは同じ車種として扱われていた。';

-- 💡 仕組み：`row_group` が同じコードどうしを「一緒に合計されていた」とみなします。
INSERT INTO legacy_cost_sheet_lines VALUES
 ('CS-2025-07','R01','JP-A11'), ('CS-2025-07','R01','CN-X123'), ('CS-2025-07','R01','TH-Z999'),
 ('CS-2025-05','R03','MTO-987'), ('CS-2025-05','R03','KR-Q777');

-- (d) クエリ履歴：Free Edition では system.query.history を使えない場合があるため、同じ形の架空テーブルで代用
-- 💡 なぜ：分析者がどのコードを一緒に使っていたかは、利用の痕跡として手がかりになります。
-- 💡 仕組み：本番では `system.query.history`（Unity Catalog のシステムテーブル）から取れます。Free Edition では使えない場合があるため、同じ形の架空テーブルで代用します。
CREATE OR REPLACE TABLE sample_query_history (
  statement_id     STRING NOT NULL,
  executed_by_role STRING COMMENT '実行者の役割（実データでは個人を特定しない形に集計して使う）',
  start_time       TIMESTAMP,
  statement_text   STRING
) COMMENT 'system.query.history の代わりの架空データ。分析者が一緒に使ったコードの手がかり。';

-- 💡 仕組み：クエリ本文の中の `\'` は、文字列の中の引用符を表すエスケープです。
INSERT INTO sample_query_history VALUES
 ('Q001','販売分析担当（架空）',TIMESTAMP'2025-08-01 10:00:00','SELECT sales_month, sum(sales_volume) FROM sales_actual WHERE sales_vehicle_code IN (\'JP-A11\', \'TH-Z999\') GROUP BY 1'),
 ('Q002','販売分析担当（架空）',TIMESTAMP'2025-08-03 15:30:00','SELECT * FROM sales_actual WHERE sales_vehicle_code IN (\'KR-Q777\', \'CN-X128\')'),
 ('Q003','原価企画担当（架空）',TIMESTAMP'2025-08-04 09:10:00','SELECT * FROM production_actual WHERE mto_code = \'MTO-987\'');

-- ---------------------------------------------------------------------
-- 5B-2. 根拠の種類と重み（判断ルール。Page「同一機種判定ルール」にも同じ内容を書く）
--   source_group が違う根拠（取引・資料・人・利用）が 2 種類以上そろわないと 70 点以上にしない
-- ---------------------------------------------------------------------
-- 💡 なぜ：根拠の強さを重みとして明示し、点数の付け方を誰でも確認・調整できるようにします。
CREATE OR REPLACE TABLE evidence_weight (
  evidence_type STRING NOT NULL,
  weight        INT    COMMENT '加点（同じ種類の根拠は何件あっても 1 回だけ加点）',
  source_group  STRING COMMENT '情報源の系統（TRANSACTION / DOCUMENT / PERSON / USAGE）',
  description   STRING
) COMMENT '根拠の種類ごとの重み（架空のルール）';

-- 💡 仕組み：情報源の系統（取引・資料・人・利用）を持たせ、系統が2つ以上そろわないと70点以上にしない、というルールに使います。
-- 💡 利点：重みは表の値なので、PoC の結果を見て業務側が調整できます。
INSERT INTO evidence_weight VALUES
 ('SHIPMENT_RECORD'   ,40,'TRANSACTION','出荷実績で、確定済みの MTO がそのコードとして出荷されている'),
 ('CO_AGGREGATION'    ,25,'DOCUMENT'   ,'過去の原価シートで、確定済みのコードと同じ行グループで合計されていた'),
 ('STAFF_NOTE'        ,15,'PERSON'     ,'担当者メモ・ヒアリングで、そのコードと車両名が一緒に書かれている'),
 ('QUERY_COOCCURRENCE', 8,'USAGE'      ,'分析クエリで、確定済みのコードと一緒に使われていた（過去の誤りも拾うので弱い根拠）');

-- ---------------------------------------------------------------------
-- 5B-3. 根拠を抽出して alias_evidence にまとめる（決定的な SQL。LLM は使わない）
-- ---------------------------------------------------------------------
-- 💡 なぜ：根拠を集める対象を、変換できていない（UNRESOLVED の）コードに絞ります。マスタの矛盾（CONFLICT）は、根拠集めではなくマスタの是正が必要なので除きます。
CREATE OR REPLACE VIEW v_unresolved_codes
COMMENT '共通機種IDに変換できていないコード（CONFLICT は根拠集めではなくマスタ是正の対象なので除く）'
AS
SELECT business_area, country, source_code, norm_code(source_code) AS norm_source_code, min(month) AS first_month
FROM v_unresolved_records
WHERE resolution_status = 'UNRESOLVED'
GROUP BY business_area, country, source_code;

-- 1つの共通機種IDにしか使われていない名称だけを使う（「Alpha」のように世代をまたぐ名称は除外）
-- 💡 なぜ：「Alpha」のように複数の世代で使われている名称をメモの手がかりにすると、誤った根拠ができてしまいます。1つの共通機種IDにしか使われていない名称だけを使います。
-- 💡 仕組み：`HAVING count(DISTINCT canonical_vehicle_id) = 1` で、一意な名称に絞ります。
CREATE OR REPLACE VIEW v_unambiguous_names AS
SELECT local_vehicle_name, max(canonical_vehicle_id) AS canonical_vehicle_id
FROM v_alias_approved
WHERE local_vehicle_name IS NOT NULL
GROUP BY local_vehicle_name
HAVING count(DISTINCT canonical_vehicle_id) = 1;

-- コード → 共通機種ID が一意に決まる確定コード（業務領域・期間を問わず、コード体系の手がかりとして使う）
-- 💡 なぜ：原価シートやクエリで一緒に使われた確定コードから、共通機種IDを引くための表です。1つの ID に決まるコードだけを使います。
CREATE OR REPLACE VIEW v_unambiguous_codes AS
SELECT norm_vehicle_code, max(canonical_vehicle_id) AS canonical_vehicle_id
FROM v_alias_approved
GROUP BY norm_vehicle_code
HAVING count(DISTINCT canonical_vehicle_id) = 1;

-- 💡 なぜ：4種類の元データから、同じ形の「根拠」の行を作ってまとめます。
-- 💡 仕組み：メモは正規表現（`regexp_extract_all`）でコードを抜き出し、`instr` で車両名を探します。クエリ履歴は `LATERAL VIEW explode` でコードの組み合わせを作ります。4種類を `UNION ALL` で1つにまとめ、`CREATE TABLE AS SELECT` で保存します。
-- 💡 利点：どの根拠が、どの元データのどの行から来たか（`evidence_id`・`evidence_detail`）を、後から確認できます。
CREATE OR REPLACE TABLE alias_evidence
COMMENT '未解決コードごとの根拠（架空）。確定情報ではなく、担当者の判断材料。'
AS
-- (a) 担当者メモ：メモ中のコードと、一意な車両名の組み合わせ
WITH note_codes AS (
  SELECT n.*, explode(regexp_extract_all(n.note_text, '[A-Z]{2,3}-[A-Z0-9]{2,6}', 0)) AS code
  FROM tacit_knowledge_notes n
)
SELECT concat('STAFF_NOTE-', nc.note_id) AS evidence_id, u.business_area, u.country, u.source_code,
       nm.canonical_vehicle_id AS candidate_vehicle_id, 'STAFF_NOTE' AS evidence_type,
       concat(nc.source_type, '「', nc.note_text, '」') AS evidence_detail,
       nc.source_document AS evidence_source, nc.recorded_by_role, nc.recorded_at
FROM note_codes nc
JOIN v_unresolved_codes u   ON norm_code(nc.code) = u.norm_source_code
JOIN v_unambiguous_names nm ON instr(upper(nc.note_text), upper(nm.local_vehicle_name)) > 0
UNION ALL
-- (b) 出荷実績：確定済み MTO（出荷月が適用期間内）→ 仕向け先コード
SELECT concat('SHIPMENT_RECORD-', s.shipment_id), u.business_area, u.country, u.source_code,
       a.canonical_vehicle_id, 'SHIPMENT_RECORD',
       concat(s.mto_code, ' を ', s.destination_country, ' に ', s.destination_model_code, ' として ', CAST(s.shipped_volume AS STRING), ' 台出荷（', CAST(s.ship_month AS STRING), '）'),
       'shipment_actual', '物流管理（架空）', s.ship_month
FROM shipment_actual s
JOIN v_alias_approved a
  ON a.business_area = 'PRODUCTION' AND a.norm_vehicle_code = norm_code(s.mto_code)
 AND s.ship_month BETWEEN a.valid_from AND a.valid_to
JOIN v_unresolved_codes u
  ON u.business_area = 'SALES' AND u.country = s.destination_country
 AND u.norm_source_code = norm_code(s.destination_model_code)
UNION ALL
-- (c) 過去の原価シート：同じ行グループの確定コードが 1 つの共通機種IDに決まる場合のみ
SELECT concat('CO_AGGREGATION-', g.sheet_id, '-', g.row_group), u.business_area, u.country, u.source_code,
       g.canonical_vehicle_id, 'CO_AGGREGATION',
       concat(g.sheet_id, ' の行グループ ', g.row_group, ' で ', array_join(g.known_codes, ', '), ' と一緒に合計'),
       concat('原価シート ', g.sheet_id, '（架空）'), '原価企画（架空）', CAST(NULL AS DATE)
FROM (
  SELECT l.sheet_id, l.row_group,
         max(c.canonical_vehicle_id) AS canonical_vehicle_id,
         array_sort(collect_set(CASE WHEN c.canonical_vehicle_id IS NOT NULL THEN l.source_code END)) AS known_codes
  FROM legacy_cost_sheet_lines l
  LEFT JOIN v_unambiguous_codes c ON c.norm_vehicle_code = norm_code(l.source_code)
  GROUP BY l.sheet_id, l.row_group
  HAVING count(DISTINCT c.canonical_vehicle_id) = 1
) g
JOIN legacy_cost_sheet_lines l2 ON l2.sheet_id = g.sheet_id AND l2.row_group = g.row_group
JOIN v_unresolved_codes u ON u.norm_source_code = norm_code(l2.source_code)
UNION ALL
-- (d) クエリ履歴：未解決コードと一緒に使われた確定コード
SELECT concat('QUERY_COOCCURRENCE-', q.statement_id, '-', q.other_code), u.business_area, u.country, u.source_code,
       c.canonical_vehicle_id, 'QUERY_COOCCURRENCE',
       concat(q.executed_by_role, ' のクエリで ', q.other_code, ' と一緒に使用（', CAST(q.start_time AS STRING), '）'),
       'sample_query_history', q.executed_by_role, CAST(q.start_time AS DATE)
FROM (
  SELECT h.statement_id, h.executed_by_role, h.start_time, a.code AS unresolved_code, b.code AS other_code
  FROM sample_query_history h
  LATERAL VIEW explode(regexp_extract_all(h.statement_text, '[A-Z]{2,3}-[A-Z0-9]{2,6}', 0)) a AS code
  LATERAL VIEW explode(regexp_extract_all(h.statement_text, '[A-Z]{2,3}-[A-Z0-9]{2,6}', 0)) b AS code
  WHERE a.code <> b.code
) q
JOIN v_unresolved_codes u   ON u.norm_source_code = norm_code(q.unresolved_code)
JOIN v_unambiguous_codes c  ON c.norm_vehicle_code = norm_code(q.other_code);

-- 💡 なぜ：抽出された根拠を確かめます。1人の検索履歴だけが Model Beta を示している点にも注目します。
SELECT source_code, candidate_vehicle_id, evidence_type, evidence_detail, recorded_by_role
FROM alias_evidence
ORDER BY source_code, candidate_vehicle_id, evidence_type;
-- 期待値（7行）:
--   TH-Z999 → VEHICLE-001 : SHIPMENT_RECORD / CO_AGGREGATION / STAFF_NOTE / QUERY_COOCCURRENCE
--   KR-Q777 → VEHICLE-001 : CO_AGGREGATION / STAFF_NOTE
--   KR-Q777 → VEHICLE-004 : QUERY_COOCCURRENCE（1人の分析者が Model Beta のコードと並べて検索しただけ）
--   N003（CN-X12）は車両名が書かれていないので根拠にならない

-- ---------------------------------------------------------------------
-- 5B-4. 根拠からスコアを計算する（どの根拠で何点かを説明できる）
-- ---------------------------------------------------------------------
-- 💡 なぜ：根拠を点数にまとめ、確認に回すかどうかを判断できるようにします。
-- 💡 仕組み：同じ種類の根拠は1回だけ加点します（同じ人が何度検索しても点数は増えません）。系統が2つ未満なら `least(..., 69)` で69点を上限にします。
-- 💡 利点：点数の内訳（`evidence_types`・`evidence_details`）が残るので、「なぜ88点か」を説明できます。
CREATE OR REPLACE VIEW v_evidence_score
COMMENT '根拠にもとづく候補スコア。同じ種類の根拠は 1 回だけ加点、独立した情報源が 2 系統未満なら 69 点で頭打ち。'
AS
WITH per_type AS (
  SELECT e.business_area, e.country, e.source_code, e.candidate_vehicle_id,
         e.evidence_type, w.weight, w.source_group,
         count(*) AS evidence_count,
         collect_list(e.evidence_detail) AS details
  FROM alias_evidence e
  JOIN evidence_weight w USING (evidence_type)
  GROUP BY e.business_area, e.country, e.source_code, e.candidate_vehicle_id, e.evidence_type, w.weight, w.source_group
)
SELECT business_area, country, source_code, candidate_vehicle_id,
       sum(weight)                     AS raw_score,
       count(DISTINCT source_group)    AS independent_sources,
       CASE WHEN count(DISTINCT source_group) >= 2 THEN least(sum(weight), 99)
            ELSE least(sum(weight), 69) END AS evidence_score,
       array_sort(collect_list(evidence_type)) AS evidence_types,
       flatten(collect_list(details))  AS evidence_details
FROM per_type
GROUP BY business_area, country, source_code, candidate_vehicle_id;

-- 💡 なぜ：候補ごとの点数と、根拠の系統の数を確かめます。
SELECT source_code, candidate_vehicle_id, raw_score, independent_sources, evidence_score, evidence_types
FROM v_evidence_score
ORDER BY source_code, evidence_score DESC;
-- 期待値: TH-Z999 / VEHICLE-001 = 88点（4系統）、KR-Q777 / VEHICLE-001 = 40点（2系統）、KR-Q777 / VEHICLE-004 = 8点（1系統）

-- 5B-5. 70点に届かない候補について、次に集めるべき根拠を示す
-- 💡 なぜ：70点に届かない候補について、次に何を集めればよいかを示します。
-- 💡 仕組み：`filter` と `array_contains` で、まだ無い根拠の種類を配列から取り出します。
-- 💡 利点：「調べる」作業が「足りない根拠を取りに行く」作業に変わり、調査の範囲が絞れます。
WITH all_types AS (SELECT collect_list(evidence_type) AS types FROM evidence_weight)
SELECT s.source_code, s.candidate_vehicle_id, s.evidence_score,
       filter(t.types, x -> NOT array_contains(s.evidence_types, x)) AS missing_evidence_types
FROM v_evidence_score s CROSS JOIN all_types t
WHERE s.evidence_score < 70
ORDER BY s.source_code, s.evidence_score DESC;
-- 期待値: KR-Q777 / VEHICLE-001 は SHIPMENT_RECORD（出荷実績）が無い → 物流部門に出荷記録を確認するのが次の一手

-- ---------------------------------------------------------------------
-- 5B-6. 根拠スコアを候補として対応表に反映する（APPROVED にはしない）
--   既存の候補（TH-Z999 の 45 点）は根拠スコアで更新し、新しい候補（KR-Q777）は CANDIDATE で追加する
-- ---------------------------------------------------------------------
-- 💡 なぜ：根拠の点数を、対応表の候補（CANDIDATE）に反映します。APPROVED にはしません。
-- 💡 仕組み：すでにある候補（TH-Z999 の45点）は点数を更新し、無い候補（KR-Q777）は追加します。`greatest` で、元の点数より下げないようにしています。
-- 💡 利点：レビューキュー（Exercise 5）の仕組みを変えずに、根拠のある候補を確認に回せます。
MERGE INTO vehicle_alias_master AS t
USING (
  SELECT s.*, u.first_month
  FROM v_evidence_score s
  JOIN v_unresolved_codes u USING (business_area, country, source_code)
) AS s
ON  t.approval_status      = 'CANDIDATE'
AND t.business_area        = s.business_area
AND t.country              = s.country
AND norm_code(t.local_vehicle_code) = norm_code(s.source_code)
AND t.canonical_vehicle_id = s.candidate_vehicle_id
WHEN MATCHED THEN UPDATE SET
  confidence_score = greatest(coalesce(t.confidence_score, 0), s.evidence_score),
  mapping_method   = 'EVIDENCE_BASED',
  source_document  = 'alias_evidence',
  remarks          = concat('根拠: ', array_join(s.evidence_types, ' / '), '（独立した情報源 ', CAST(s.independent_sources AS STRING), ' 系統）'),
  updated_at       = current_timestamp()
WHEN NOT MATCHED THEN INSERT
  (alias_id, canonical_vehicle_id, country, business_area, local_vehicle_name, local_vehicle_code,
   valid_from, valid_to, approval_status, confidence_score, mapping_method, source_document, approved_by, remarks, updated_at)
VALUES
  (concat('EVID-', s.source_code, '-', s.candidate_vehicle_id), s.candidate_vehicle_id, s.country, s.business_area,
   NULL, s.source_code, s.first_month, DATE'9999-12-31', 'CANDIDATE', s.evidence_score, 'EVIDENCE_BASED', 'alias_evidence', NULL,
   concat('根拠: ', array_join(s.evidence_types, ' / '), '（独立した情報源 ', CAST(s.independent_sources AS STRING), ' 系統）'),
   current_timestamp());

-- 5B-7. レビューキューを再確認（Exercise 5 と同じ View。分類ルールは変えていない）
-- 💡 なぜ：同じ分類ルールのまま、根拠によって分類が変わったことを確かめます。
SELECT review_category, source_code, top_score, candidate_count, candidate_list
FROM v_alias_review_queue
WHERE source_code IN ('TH-Z999', 'KR-Q777');
-- 期待値:
--   TH-Z999 : 未解決（45点） → 要確認（88点）。担当者は 4 系統の根拠を見て判断できる
--   KR-Q777 : 未解決（候補なし） → 未解決（候補 2 件、最高 40 点）。根拠不足なので確認には回さず、出荷記録を集める

-- 5B-8. 集計への影響：候補になっただけでは採算 View は変わらない（2025-07 の販売台数は 3,280 台のまま）
-- 💡 なぜ：候補になっただけでは、集計の数字が変わらないことを確かめます（人が承認するまでは集計に入りません）。
SELECT month, sales_volume FROM v_vehicle_monthly_profitability
WHERE canonical_vehicle_id = 'VEHICLE-001' AND month = DATE'2025-07-01';

-- ---------------------------------------------------------------------
-- 5B-9. （任意）担当者が根拠を確認して TH-Z999 を承認する場合
-- ---------------------------------------------------------------------
-- UPDATE vehicle_alias_master
-- SET approval_status = 'APPROVED', mapping_method = 'HUMAN_REVIEWED',
--     approved_by = 'タイ営業企画 マスタ管理担当（架空）', updated_at = current_timestamp()
-- WHERE alias_id = 'A018';
--   → 2025-07 の販売台数が 3,280 → 3,340 台になる。※ 98_verify_expected_values は未承認の状態を前提にしている

-- ---------------------------------------------------------------------
-- 5B-10. （任意）実環境での根拠の集め方の例
-- ---------------------------------------------------------------------
-- 担当者の Excel・メモを AI Functions で構造化する例（ボリュームに置いたファイルが対象）
-- SELECT note_id, ai_extract(note_text, array('vehicle_code', 'vehicle_name')) AS extracted FROM tacit_knowledge_notes;

-- 実際のクエリ履歴を使う例（system tables の閲覧権限が必要。利用者は個人を特定しない形に集計して使う）
-- SELECT regexp_extract_all(statement_text, '[A-Z]{2,3}-[A-Z0-9]{2,6}', 0) AS codes, count(*) AS n
-- FROM system.query.history
-- WHERE statement_text ILIKE '%TH-Z999%' AND start_time >= current_date() - INTERVAL 90 DAYS
-- GROUP BY ALL;
