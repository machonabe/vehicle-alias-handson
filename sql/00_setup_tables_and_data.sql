-- =====================================================================
-- 00_setup_tables_and_data.sql
-- 目的 : ハンズオン用の架空データ（テーブルDDL + INSERT）を作成する
-- 実行 : ノートブック版（推奨）はそのまま上から実行。SQL エディタの場合は下の USE 文を自分の値に変更して実行
-- 注意 : すべての名称・コード・数値・部署名は架空です。実在企業の機密データは含みません。
--        金額の単位はすべて「百万円」、台数の単位は「台」です。
-- =====================================================================

-- @config-begin  ノートブック版では 00_config がカタログ・スキーマを設定するため、この範囲は自動で除去されます
-- カタログ・スキーマ（既定値は Free Edition の既定カタログ workspace に作成する設定）
--   講師用（Pageの Related assets が参照する公式スキーマ）: vehicle_alias_handson
--   参加者用 : vehicle_alias_handson_<自分のイニシャル>  例) vehicle_alias_handson_tw
USE CATALOG workspace;             -- ★ SQL エディタで実行する場合は config/00_config と同じ値にする
CREATE SCHEMA IF NOT EXISTS vehicle_alias_handson
  COMMENT 'Vehicle Profitability ハンズオン（架空データ）';
USE SCHEMA vehicle_alias_handson;  -- ★ 同上
-- @config-end

-- ---------------------------------------------------------------------
-- 0. 正規化関数（全角→半角、大文字化、記号・空白除去）
-- ---------------------------------------------------------------------
-- コード用 : 英数字以外をすべて除去する   'ＪＰ－Ａ１１' / 'jp-a11 ' → 'JPA11'
CREATE OR REPLACE FUNCTION norm_code(s STRING)
RETURNS STRING
COMMENT '機種コードの表記揺れ正規化（全角→半角、大文字化、英数字以外を除去）'
RETURN regexp_replace(
  upper(translate(s,
    'ＡＢＣＤＥＦＧＨＩＪＫＬＭＮＯＰＱＲＳＴＵＶＷＸＹＺａｂｃｄｅｆｇｈｉｊｋｌｍｎｏｐｑｒｓｔｕｖｗｘｙｚ０１２３４５６７８９－　',
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789- ')),
  '[^A-Z0-9]', '');

-- 名称用 : 漢字等は残し、空白・記号のみ除去する   'Ａｌｐｈａ　１１Ｍ' / 'ALPHA 11 M' → 'ALPHA11M'
CREATE OR REPLACE FUNCTION norm_name(s STRING)
RETURNS STRING
COMMENT '車種名称の表記揺れ正規化（全角→半角、大文字化、空白・記号を除去。簡体字/繁体字の変換は行わない）'
RETURN regexp_replace(
  upper(translate(s,
    'ＡＢＣＤＥＦＧＨＩＪＫＬＭＮＯＰＱＲＳＴＵＶＷＸＹＺａｂｃｄｅｆｇｈｉｊｋｌｍｎｏｐｑｒｓｔｕｖｗｘｙｚ０１２３４５６７８９－　',
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789- ')),
  '[\\s\\-_.・()（）]', '');

-- ---------------------------------------------------------------------
-- 1. canonical_vehicle : 共通機種（人が定義した「同じ車両」の単位）
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE canonical_vehicle (
  canonical_vehicle_id STRING NOT NULL COMMENT '共通機種ID（例: VEHICLE-001）',
  global_vehicle_name  STRING NOT NULL COMMENT 'グローバル名称',
  vehicle_series       STRING COMMENT '車両系列',
  generation           INT    COMMENT '世代',
  powertrain_scope     STRING COMMENT 'この共通機種に含めるパワートレイン',
  lifecycle_status     STRING COMMENT 'ACTIVE / RUN_OUT（販売終了移行中）',
  launch_date          DATE   COMMENT '初回発売日（架空）',
  description          STRING COMMENT '補足'
) COMMENT '共通機種マスタ（架空）。1行=1つの「同じ車両」概念。';

INSERT INTO canonical_vehicle VALUES
 ('VEHICLE-001','Model Alpha 11th Gen'   ,'Alpha',11,'ICE / HEV','ACTIVE' ,DATE'2024-04-01','Alpha系列 第11世代。ガソリン・HEVを含む'),
 ('VEHICLE-002','Model Alpha 10th Gen'   ,'Alpha',10,'ICE'        ,'RUN_OUT',DATE'2019-04-01','Alpha系列 第10世代（先代）。名称「Alpha」は共通だが別機種'),
 ('VEHICLE-003','Model Alpha 11th Gen EV','Alpha',11,'BEV'        ,'ACTIVE' ,DATE'2025-07-01','第11世代ベースの派生EV。別開発プロジェクトのため別機種'),
 ('VEHICLE-004','Model Beta 3rd Gen'     ,'Beta' , 3,'ICE'        ,'ACTIVE' ,DATE'2023-01-01','別系列（候補の紛らわしさを再現するため）');

-- ---------------------------------------------------------------------
-- 2. vehicle_alias_master : 国・部門・システム別の名称/コード → 共通機種ID 対応表
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE vehicle_alias_master (
  alias_id             STRING NOT NULL COMMENT '対応レコードID',
  canonical_vehicle_id STRING COMMENT '共通機種ID',
  country              STRING COMMENT '国（JP / CN / TH / GLOBAL など）',
  business_area        STRING COMMENT 'SALES / PRODUCTION / DEVELOPMENT / AFTERSALES',
  local_vehicle_name   STRING COMMENT '国・部門での名称',
  local_vehicle_code   STRING COMMENT '国・部門・システムでの機種コード / MTOコード',
  valid_from           DATE   COMMENT '適用開始日',
  valid_to             DATE   COMMENT '適用終了日（無期限は 9999-12-31）',
  approval_status      STRING COMMENT 'APPROVED=確定 / CANDIDATE=候補（未確定） / PENDING=登録途中 / REJECTED=却下',
  confidence_score     INT    COMMENT '対応の信頼度（0-100）。CANDIDATE はAI・ルールによる推定値',
  mapping_method       STRING COMMENT 'SPEC_MASTER / HISTORY / AI_SUGGESTED / HUMAN_REVIEWED / MANUAL_ENTRY',
  source_document      STRING COMMENT '根拠資料（架空）',
  approved_by          STRING COMMENT '承認者（架空の部署・役割名。個人名は入れない）',
  remarks              STRING COMMENT '備考',
  updated_at           TIMESTAMP COMMENT '更新日時'
) COMMENT '車両名称・機種コード対応表（架空）。確定的な集計には approval_status = APPROVED の行のみを使用する。';

INSERT INTO vehicle_alias_master VALUES
 -- 完全一致で対応できる確定コード（Model Alpha 11th Gen）
 ('A001','VEHICLE-001','JP'    ,'SALES'      ,'Alpha'      ,'JP-A11'  ,DATE'2024-04-01',DATE'9999-12-31','APPROVED',100,'SPEC_MASTER','SPEC-A11-ALIAS-001 Rev.3（架空）','商品企画部（架空）',NULL,current_timestamp()),
 ('A002','VEHICLE-001','CN'    ,'SALES'      ,'阿尔法'     ,'CN-X123' ,DATE'2025-06-01',DATE'9999-12-31','APPROVED',100,'SPEC_MASTER','SPEC-A11-ALIAS-001 Rev.3（架空）','中国営業企画（架空）','2025-06 の販売システム移行で CN-X123B から変更',current_timestamp()),
 ('A003','VEHICLE-001','GLOBAL','DEVELOPMENT','Project A11','DEV-A11' ,DATE'2022-01-01',DATE'9999-12-31','APPROVED',100,'SPEC_MASTER','SPEC-A11-ALIAS-001 Rev.3（架空）','開発企画（架空）',NULL,current_timestamp()),
 ('A004','VEHICLE-001','JP'    ,'PRODUCTION' ,'Alpha 11M'  ,'MTO-987' ,DATE'2024-02-01',DATE'9999-12-31','APPROVED',100,'SPEC_MASTER','SPEC-A11-ALIAS-001 Rev.3（架空）','生産管理（架空）',NULL,current_timestamp()),
 -- 先代（名称「Alpha」は同じだが別機種）
 ('A005','VEHICLE-002','JP'    ,'SALES'      ,'Alpha'      ,'JP-A10'  ,DATE'2019-04-01',DATE'2025-06-30','APPROVED',100,'SPEC_MASTER','SPEC-A10-ALIAS-001 Rev.5（架空）','商品企画部（架空）','先代。2025-06 末で販売終了',current_timestamp()),
 ('A006','VEHICLE-002','GLOBAL','DEVELOPMENT','Project A10','DEV-A10' ,DATE'2016-01-01',DATE'2019-03-31','APPROVED',100,'SPEC_MASTER','SPEC-A10-ALIAS-001 Rev.5（架空）','開発企画（架空）',NULL,current_timestamp()),
 ('A007','VEHICLE-002','JP'    ,'PRODUCTION' ,'Alpha 10M'  ,'MTO-950' ,DATE'2019-03-01',DATE'2024-01-31','APPROVED',100,'SPEC_MASTER','SPEC-A10-ALIAS-001 Rev.5（架空）','生産管理（架空）',NULL,current_timestamp()),
 -- 派生EV（同じ世代だが別プロジェクト → 別機種）
 ('A008','VEHICLE-003','JP'    ,'SALES'      ,'Alpha e'    ,'JP-A11E' ,DATE'2025-07-01',DATE'9999-12-31','APPROVED',100,'SPEC_MASTER','SPEC-A11E-ALIAS-001 Rev.1（架空）','商品企画部（架空）',NULL,current_timestamp()),
 ('A009','VEHICLE-003','GLOBAL','DEVELOPMENT','Project A11e','DEV-A11E',DATE'2023-04-01',DATE'9999-12-31','APPROVED',100,'SPEC_MASTER','SPEC-A11E-ALIAS-001 Rev.1（架空）','開発企画（架空）',NULL,current_timestamp()),
 ('A010','VEHICLE-003','JP'    ,'PRODUCTION' ,'Alpha 11M-EV','MTO-995',DATE'2025-06-01',DATE'9999-12-31','APPROVED',100,'SPEC_MASTER','SPEC-A11E-ALIAS-001 Rev.1（架空）','生産管理（架空）',NULL,current_timestamp()),
 -- 別系列
 ('A011','VEHICLE-004','CN'    ,'SALES'      ,'贝塔'       ,'CN-X128' ,DATE'2023-01-01',DATE'9999-12-31','APPROVED',100,'SPEC_MASTER','SPEC-B03-ALIAS-001 Rev.2（架空）','中国営業企画（架空）',NULL,current_timestamp()),
 -- ★ 不正：同じ MTO-990 が期間重複で 2つの共通機種IDに APPROVED（Exercise 6 で検出）
 ('A012','VEHICLE-001','JP'    ,'PRODUCTION' ,'Alpha 11M'  ,'MTO-990' ,DATE'2025-01-01',DATE'9999-12-31','APPROVED',100,'MANUAL_ENTRY','生産管理 手入力（架空）','生産管理（架空）','手入力で登録',current_timestamp()),
 ('A013','VEHICLE-003','JP'    ,'PRODUCTION' ,'Alpha 11M-EV','MTO-990',DATE'2025-01-01',DATE'9999-12-31','APPROVED',100,'MANUAL_ENTRY','生産管理 手入力（架空）','生産管理（架空）','手入力で登録',current_timestamp()),
 -- 候補（未確定）：AI/ルールによる推定。確定マスタではない（Exercise 5）
 ('A014','VEHICLE-001','JP'    ,'SALES'      ,'Alpha 特別仕様車','JP-A11-SE',DATE'2025-09-01',DATE'9999-12-31','CANDIDATE',96,'AI_SUGGESTED','候補生成ジョブ（架空）',NULL,'JP-A11 と前方一致・同一販売チャネル',current_timestamp()),
 ('A015','VEHICLE-001','JP'    ,'PRODUCTION' ,'Alpha 11M（追加MTO）','MTO-988',DATE'2025-09-01',DATE'9999-12-31','CANDIDATE',91,'AI_SUGGESTED','候補生成ジョブ（架空）',NULL,'MTO-987 と部品構成が 92% 一致',current_timestamp()),
 ('A016','VEHICLE-001','CN'    ,'SALES'      ,'阿尔法?'    ,'CN-X12'  ,DATE'2025-08-01',DATE'9999-12-31','CANDIDATE',82,'AI_SUGGESTED','候補生成ジョブ（架空）',NULL,'CN-X123 の桁落ちの可能性',current_timestamp()),
 ('A017','VEHICLE-004','CN'    ,'SALES'      ,'贝塔?'      ,'CN-X12'  ,DATE'2025-08-01',DATE'9999-12-31','CANDIDATE',78,'AI_SUGGESTED','候補生成ジョブ（架空）',NULL,'CN-X128 の桁落ちの可能性',current_timestamp()),
 ('A018','VEHICLE-001','TH'    ,'SALES'      ,NULL         ,'TH-Z999' ,DATE'2025-07-01',DATE'9999-12-31','CANDIDATE',45,'AI_SUGGESTED','候補生成ジョブ（架空）',NULL,'類似度低。根拠不十分',current_timestamp()),
 -- ★ 不正：必須項目（コード・適用期間）が欠損（Exercise 6 で検出）
 ('A019','VEHICLE-001','JP'    ,'AFTERSALES' ,'Alpha Service',NULL    ,NULL           ,NULL            ,'PENDING' ,NULL,'MANUAL_ENTRY',NULL,NULL,'登録途中',current_timestamp());

-- ---------------------------------------------------------------------
-- 3. alias_mapping_history : 過去に人手で作成した対応履歴（Excel取込を想定）
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE alias_mapping_history (
  history_id        STRING NOT NULL COMMENT '履歴ID',
  source_system     STRING COMMENT '元システム / 元資料',
  country           STRING COMMENT '国',
  business_area     STRING COMMENT '業務領域',
  source_name       STRING COMMENT '元資料上の名称（表記揺れあり）',
  source_code       STRING COMMENT '元資料上のコード（無い場合あり）',
  mapped_vehicle_id STRING COMMENT '人が対応づけた共通機種ID（不明なら NULL）',
  valid_from        DATE,
  valid_to          DATE,
  history_status    STRING COMMENT 'APPROVED / UNKNOWN',
  approved_by       STRING COMMENT '承認した部署・役割（架空）',
  approved_at       DATE,
  source_document   STRING COMMENT '元資料名（架空）'
) COMMENT '過去の人手対応履歴（架空）。一部のみ存在し、名称だけのものもある。';

INSERT INTO alias_mapping_history VALUES
 ('H001','CN_SALES_LEGACY','CN','SALES'     ,'阿尔法'           ,'CN-X123B','VEHICLE-001',DATE'2024-07-01',DATE'2025-05-31','APPROVED','中国営業企画（架空）',DATE'2024-06-20','Alpha系列 名称対応表 v3.xlsx（架空）'),
 ('H002','COST_SHEET'     ,'JP','PRODUCTION','ALPHA 11 M'       ,NULL      ,'VEHICLE-001',NULL,NULL,'APPROVED','原価企画（架空）',DATE'2024-03-10','原価積上げシート_A11.xlsx（架空）'),
 ('H003','COST_SHEET'     ,'JP','PRODUCTION','Ａｌｐｈａ　１１Ｍ',NULL      ,'VEHICLE-001',NULL,NULL,'APPROVED','原価企画（架空）',DATE'2024-03-10','原価積上げシート_A11.xlsx（架空）'),
 ('H004','COST_SHEET'     ,'JP','SALES'     ,'alpha'            ,NULL      ,NULL         ,NULL,NULL,'UNKNOWN' ,'原価企画（架空）',DATE'2024-03-10','原価積上げシート_A11.xlsx（架空）'),
 ('H005','CN_SALES_LEGACY','CN','SALES'     ,'阿爾法'           ,NULL      ,NULL         ,NULL,NULL,'UNKNOWN' ,'中国営業企画（架空）',DATE'2024-06-20','Alpha系列 名称対応表 v3.xlsx（架空）');

-- ---------------------------------------------------------------------
-- 4. development_plan : 開発計画（開発コード × 月）
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE development_plan (
  plan_record_id           STRING NOT NULL,
  development_vehicle_code STRING COMMENT '開発コード（DEV-xxx）',
  plan_year                INT    COMMENT '計画年度',
  plan_month               DATE   COMMENT '計画月（月初日）',
  planned_volume           INT    COMMENT '計画台数（台）',
  planned_material_cost    DECIMAL(12,1) COMMENT '計画材料費（百万円・架空）',
  planned_sales            DECIMAL(12,1) COMMENT '計画売上（百万円・架空）',
  plan_version             STRING COMMENT '計画版'
) COMMENT '開発計画（架空）。開発コード単位で、販売・生産とはコード体系が異なる。';

INSERT INTO development_plan VALUES
 ('D001','DEV-A11' ,2025,DATE'2025-04-01',3500,6300,10500,'FY25-v2'),
 ('D002','DEV-A11' ,2025,DATE'2025-05-01',3500,6300,10500,'FY25-v2'),
 ('D003','DEV-A11' ,2025,DATE'2025-06-01',3600,6480,10800,'FY25-v2'),
 ('D004','DEV-A11' ,2025,DATE'2025-07-01',3600,6480,10800,'FY25-v2'),
 ('D005','DEV-A11' ,2025,DATE'2025-08-01',3700,6660,11100,'FY25-v2'),
 ('D006','DEV-A11' ,2025,DATE'2025-09-01',3800,6840,11400,'FY25-v2'),
 ('D007','DEV-A11E',2025,DATE'2025-07-01', 100, 320,  500,'FY25-v2'),
 ('D008','DEV-A11E',2025,DATE'2025-08-01', 100, 320,  500,'FY25-v2'),
 ('D009','DEV-A11E',2025,DATE'2025-09-01', 100, 320,  500,'FY25-v2');

-- ---------------------------------------------------------------------
-- 5. sales_actual : 販売実績（国 × 販売コード × パワートレイン × 月）
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE sales_actual (
  sales_record_id    STRING NOT NULL,
  country            STRING COMMENT '販売国',
  sales_vehicle_code STRING COMMENT '販売システムの機種コード（表記揺れあり）',
  powertrain         STRING COMMENT 'GAS / HEV / EV',
  body_type          STRING COMMENT 'ドア形状（例: 5D）',
  sales_volume       INT    COMMENT '販売台数（台）',
  actual_sales       DECIMAL(12,1) COMMENT '売上実績（百万円・架空）',
  sales_month        DATE   COMMENT '販売月（月初日）',
  source_system      STRING COMMENT '元システム'
) COMMENT '販売実績（架空）。営業は車種・ドア・パワートレイン単位で管理。';

INSERT INTO sales_actual VALUES
 ('S001','JP','JP-A11'     ,'HEV','5D',1200,4080,DATE'2025-04-01','JP_SALES'),
 ('S002','JP','JP-A11'     ,'GAS'  ,'5D', 800,2400,DATE'2025-04-01','JP_SALES'),
 ('S003','JP','JP-A11'     ,'HEV','5D',1250,4250,DATE'2025-05-01','JP_SALES'),
 ('S004','JP','JP-A11'     ,'GAS'  ,'5D', 780,2340,DATE'2025-05-01','JP_SALES'),
 ('S005','JP','JP-A11'     ,'HEV','5D',1300,4420,DATE'2025-06-01','JP_SALES'),
 ('S006','JP','jp-a11 '    ,'GAS'  ,'5D', 760,2280,DATE'2025-06-01','JP_SALES'),   -- 表記揺れ（小文字・末尾空白）
 ('S007','JP','JP-A11'     ,'HEV','5D',1280,4352,DATE'2025-07-01','JP_SALES'),
 ('S008','JP','JP-A11'     ,'GAS'  ,'5D', 750,2250,DATE'2025-07-01','JP_SALES'),
 ('S009','JP','ＪＰ－Ａ１１','HEV','5D',1350,4590,DATE'2025-08-01','JP_SALES'),  -- 表記揺れ（全角）
 ('S010','JP','JP-A11'     ,'GAS'  ,'5D', 700,2100,DATE'2025-08-01','JP_SALES'),
 ('S011','JP','JP-A11'     ,'HEV','5D',1400,4760,DATE'2025-09-01','JP_SALES'),
 ('S012','JP','JP-A11'     ,'GAS'  ,'5D', 720,2160,DATE'2025-09-01','JP_SALES'),
 ('S013','CN','CN-X123B'   ,'GAS'  ,'5D',1100,2860,DATE'2025-04-01','CN_SALES_LEGACY'), -- 旧システムコード（過去履歴で対応）
 ('S014','CN','CN-X123B'   ,'GAS'  ,'5D',1150,2990,DATE'2025-05-01','CN_SALES_LEGACY'),
 ('S015','CN','CN-X123'    ,'GAS'  ,'5D',1200,3120,DATE'2025-06-01','CN_SALES'),
 ('S016','CN','CN-X123'    ,'GAS'  ,'5D',1250,3250,DATE'2025-07-01','CN_SALES'),
 ('S017','CN','CN-X123'    ,'GAS'  ,'5D',1300,3380,DATE'2025-08-01','CN_SALES'),
 ('S018','CN','CN-X123'    ,'GAS'  ,'5D',1350,3510,DATE'2025-09-01','CN_SALES'),
 ('S019','JP','JP-A10'     ,'GAS'  ,'5D', 150, 405,DATE'2025-04-01','JP_SALES'),   -- 先代の在庫販売（別機種）
 ('S020','JP','JP-A11E'    ,'EV'   ,'5D',  80, 400,DATE'2025-07-01','JP_SALES'),   -- 派生EV（別機種）
 ('S021','JP','JP-A11E'    ,'EV'   ,'5D',  90, 450,DATE'2025-08-01','JP_SALES'),
 ('S022','JP','JP-A11E'    ,'EV'   ,'5D', 100, 500,DATE'2025-09-01','JP_SALES'),
 ('S023','CN','CN-X12'     ,'GAS'  ,'5D',  90, 234,DATE'2025-08-01','CN_SALES'),   -- 候補が複数（要確認）
 ('S024','JP','JP-A11-SE'  ,'HEV','5D', 120, 432,DATE'2025-09-01','JP_SALES'),   -- 高信頼の候補のみ（自動承認候補）
 ('S025','TH','TH-Z999'    ,'GAS'  ,'5D',  60, 150,DATE'2025-07-01','TH_SALES'),   -- 低信頼（未解決）
 ('S026','KR','KR-Q777'    ,'HEV','5D',  40, 110,DATE'2025-05-01','KR_SALES');   -- 対応表に存在しない（未解決）

-- ---------------------------------------------------------------------
-- 6. production_actual : 生産実績（MTOコード × 月）
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE production_actual (
  production_record_id STRING NOT NULL,
  plant_code           STRING COMMENT '工場（架空）',
  mto_code             STRING COMMENT 'MTOコード（表記揺れあり）',
  production_volume    INT    COMMENT '生産台数（台）',
  actual_material_cost DECIMAL(12,1) COMMENT '材料費実績（百万円・架空）',
  production_month     DATE   COMMENT '生産月（月初日）'
) COMMENT '生産実績（架空）。生産は MTO・部品単位で管理。';

INSERT INTO production_actual VALUES
 ('P001','PLANT-J1','MTO-987' ,3300,6110,DATE'2025-04-01'),
 ('P002','PLANT-J1','MTO-987' ,3350,6200,DATE'2025-05-01'),
 ('P003','PLANT-J1','mto-987 ',3400,6320,DATE'2025-06-01'),  -- 表記揺れ
 ('P004','PLANT-J1','MTO-987' ,3420,6350,DATE'2025-07-01'),
 ('P005','PLANT-J1','MTO-987' ,3500,7150,DATE'2025-08-01'),  -- 実績原価が突出（BOM重複の影響を想定）
 ('P006','PLANT-J1','MTO-987' ,3550,6600,DATE'2025-09-01'),
 ('P007','PLANT-J1','MTO-995' ,  90, 290,DATE'2025-07-01'),  -- 派生EV（別機種）
 ('P008','PLANT-J1','MTO-995' , 100, 320,DATE'2025-08-01'),
 ('P009','PLANT-J1','MTO-995' , 110, 352,DATE'2025-09-01'),
 ('P010','PLANT-J1','MTO-988' , 100, 190,DATE'2025-09-01'),  -- 候補のみ（要確認）
 ('P011','PLANT-J1','MTO-990' ,  50,  95,DATE'2025-07-01');  -- マスタ矛盾（2つの共通機種IDに APPROVED）

-- ---------------------------------------------------------------------
-- 7. vehicle_bom : 部品表（MTO × 部品）
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE vehicle_bom (
  bom_line_id          STRING NOT NULL,
  mto_code             STRING COMMENT 'MTOコード',
  part_category        STRING COMMENT '部品カテゴリ（TIRE / WHEEL / ENGINE など）',
  part_code            STRING COMMENT '部品コード（架空）',
  part_name            STRING COMMENT '部品名（架空）',
  quantity_per_vehicle INT    COMMENT '1台当たり数量',
  bom_revision         STRING COMMENT 'BOM改訂',
  source_system        STRING COMMENT '取込元',
  loaded_at            TIMESTAMP COMMENT '取込日時'
) COMMENT '部品表（架空）。重複取込・旧版残存による不整合を含む。';

INSERT INTO vehicle_bom VALUES
 ('B001','MTO-987','ENGINE' ,'EN-15T'      ,'1.5L エンジン（架空）'     ,1,'B','PROD_BOM',TIMESTAMP'2025-07-31 02:00:00'),
 ('B002','MTO-987','MOTOR'  ,'MT-H01'      ,'HEVモーター（架空）'       ,1,'B','PROD_BOM',TIMESTAMP'2025-07-31 02:00:00'),
 ('B003','MTO-987','TIRE'   ,'TR-225-55R18','タイヤ 225/55R18（架空）'  ,4,'B','PROD_BOM',TIMESTAMP'2025-07-31 02:00:00'),  -- 正常
 ('B004','MTO-987','TIRE'   ,'TR-225-55R18','タイヤ 225/55R18（架空）'  ,2,'A','PROD_BOM',TIMESTAMP'2025-07-31 02:00:00'),  -- ★旧版残存 → 合計6本
 ('B005','MTO-987','WHEEL'  ,'WH-18A'      ,'ホイール 18インチ（架空）' ,4,'B','PROD_BOM',TIMESTAMP'2025-07-31 02:00:00'),
 ('B006','MTO-987','BATTERY','BT-12V'      ,'12Vバッテリー（架空）'     ,1,'B','PROD_BOM',TIMESTAMP'2025-07-31 02:00:00'),
 ('B007','MTO-987','BATTERY','BT-12V'      ,'12Vバッテリー（架空）'     ,1,'B','PROD_BOM',TIMESTAMP'2025-08-01 02:00:00'),  -- ★二重取込
 ('B008','MTO-995','TIRE'   ,'TR-235-50R19','タイヤ 235/50R19（架空）'  ,4,'A','PROD_BOM',TIMESTAMP'2025-07-31 02:00:00'),
 ('B009','MTO-995','MOTOR'  ,'MT-E01'      ,'駆動モーター（架空）'      ,1,'A','PROD_BOM',TIMESTAMP'2025-07-31 02:00:00'),
 ('B010','MTO-995','BATTERY','BT-HV01'     ,'駆動用バッテリー（架空）'  ,1,'A','PROD_BOM',TIMESTAMP'2025-07-31 02:00:00'),
 ('B011','MTO-950','TIRE'   ,'TR-215-55R17','タイヤ 215/55R17（架空）'  ,4,'C','PROD_BOM',TIMESTAMP'2024-01-31 02:00:00'),
 ('B012','MTO-950','ENGINE' ,'EN-15N'      ,'1.5L エンジン 旧型（架空）',1,'C','PROD_BOM',TIMESTAMP'2024-01-31 02:00:00');

-- ---------------------------------------------------------------------
-- 8. 業務ドメインのタグ付け（Domains UI が使えない場合の代替・検索性向上）
-- ---------------------------------------------------------------------
ALTER TABLE canonical_vehicle     SET TAGS ('handson_business_domain' = 'Vehicle Profitability');
ALTER TABLE vehicle_alias_master  SET TAGS ('handson_business_domain' = 'Vehicle Profitability', 'data_role' = 'mapping_master');
ALTER TABLE alias_mapping_history SET TAGS ('handson_business_domain' = 'Vehicle Profitability', 'data_role' = 'mapping_history');
ALTER TABLE development_plan      SET TAGS ('handson_business_domain' = 'Vehicle Profitability', 'data_role' = 'plan');
ALTER TABLE sales_actual          SET TAGS ('handson_business_domain' = 'Vehicle Profitability', 'data_role' = 'actual');
ALTER TABLE production_actual     SET TAGS ('handson_business_domain' = 'Vehicle Profitability', 'data_role' = 'actual');
ALTER TABLE vehicle_bom           SET TAGS ('handson_business_domain' = 'Vehicle Profitability', 'data_role' = 'bom');

-- 件数確認（期待値: 4 / 19 / 5 / 9 / 26 / 11 / 12）
SELECT 'canonical_vehicle' AS t, count(*) AS n FROM canonical_vehicle UNION ALL
SELECT 'vehicle_alias_master' , count(*) FROM vehicle_alias_master  UNION ALL
SELECT 'alias_mapping_history', count(*) FROM alias_mapping_history UNION ALL
SELECT 'development_plan'     , count(*) FROM development_plan      UNION ALL
SELECT 'sales_actual'         , count(*) FROM sales_actual          UNION ALL
SELECT 'production_actual'    , count(*) FROM production_actual     UNION ALL
SELECT 'vehicle_bom'          , count(*) FROM vehicle_bom;
