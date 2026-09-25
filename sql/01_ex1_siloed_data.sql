-- =====================================================================
-- 01_ex1_siloed_data.sql  Exercise 1：分断されたデータを確認する（10分）
-- =====================================================================
-- 💡 なぜ：対応づけの必要性を実感するために、まず「そのままでは何ができないか」を確かめます。
-- 💡 仕組み：ここでは読み取りの SELECT だけを実行し、データは変更しません。
-- @config-begin  ノートブック版では 00_config がカタログ・スキーマを設定するため、この範囲は自動で除去されます
USE CATALOG workspace;             -- ★ SQL エディタで実行する場合は config/00_config と同じ値にする
USE SCHEMA vehicle_alias_handson;  -- ★ 同上
-- @config-end

-- 1-1. 各システムのコードを並べて見る（同じ車両なのにコードが全部違う）
-- 💡 仕組み：3つのテーブルのコードを `UNION ALL` で縦に並べ、`GROUP BY ALL`（SELECT のうち集計以外の列すべてでグループ化する書き方）で数えます。
-- 💡 利点：システムごとにコード体系が違うことが、一目で分かります。
SELECT 'DEVELOPMENT' AS system, development_vehicle_code AS vehicle_code, count(*) AS rows FROM development_plan  GROUP BY ALL
UNION ALL
SELECT 'SALES'      , sales_vehicle_code, count(*) FROM sales_actual      GROUP BY ALL
UNION ALL
SELECT 'PRODUCTION' , mto_code          , count(*) FROM production_actual GROUP BY ALL
ORDER BY system, vehicle_code;

-- 1-2. 計画 × 販売をコードでそのまま JOIN → 0 件
-- 💡 なぜ：コードをそのまま結合のキーにできないことを、0件という結果で確かめます。これが、人が対応表を作っている理由です。
SELECT p.plan_month, p.development_vehicle_code, s.sales_vehicle_code, s.sales_volume
FROM development_plan p
JOIN sales_actual s
  ON p.development_vehicle_code = s.sales_vehicle_code
 AND p.plan_month = s.sales_month;

-- 1-3. 販売 × 生産をコードでそのまま JOIN → 0 件
-- 💡 仕組み：販売コードと MTO コードは体系が違うので、同じ月でも一致する行はありません。
SELECT s.sales_month, s.sales_vehicle_code, pr.mto_code
FROM sales_actual s
JOIN production_actual pr
  ON s.sales_vehicle_code = pr.mto_code
 AND s.sales_month = pr.production_month;

-- 1-4. 「名前なら一致するのでは？」→ 'Alpha' は先代（10th Gen）でも使われており、名称だけでは判定できない
-- 💡 なぜ：「名称で結合すればよいのでは」という発想の落とし穴を確かめます。「Alpha」は2つの世代で使われています。
-- 💡 利点：Page に「名称だけで判定しない」ルールを書く理由が分かります。
SELECT local_vehicle_name, local_vehicle_code, canonical_vehicle_id, valid_from, valid_to
FROM vehicle_alias_master
WHERE upper(local_vehicle_name) = 'ALPHA';

-- 1-5. 同じ「日本の Alpha」でもコードの表記揺れがある（完全一致では拾えない）
-- 💡 なぜ：人の目には同じでも、システム上は別の文字列です。完全一致だけに頼ると、これらの行が集計から漏れます。
-- 💡 仕組み：`length()` を見ると、末尾の空白や全角の文字があることも分かります。
SELECT sales_record_id, sales_vehicle_code,
       length(sales_vehicle_code) AS len,
       sales_vehicle_code = 'JP-A11' AS exact_match
FROM sales_actual
WHERE country = 'JP' AND sales_vehicle_code NOT IN ('JP-A10', 'JP-A11E', 'JP-A11-SE');

-- 1-6. 粒度の違い：販売は「パワートレイン × 月」、生産は「MTO × 月」、計画は「開発コード × 月」
-- 💡 なぜ：コードを対応づけできても、粒度が違うまま明細で結合すると、行が掛け算で増えて金額が重複します。
-- 💡 利点：Exercise 2 で「集計してから結合する」理由になります。
SELECT 'sales_actual' AS t, sales_month AS month, count(*) AS rows_per_month
FROM sales_actual WHERE norm_code(sales_vehicle_code) IN ('JPA11', 'CNX123', 'CNX123B') GROUP BY ALL
UNION ALL
SELECT 'production_actual', production_month, count(*) FROM production_actual WHERE norm_code(mto_code) = 'MTO987' GROUP BY ALL
UNION ALL
SELECT 'development_plan', plan_month, count(*) FROM development_plan WHERE development_vehicle_code = 'DEV-A11' GROUP BY ALL
ORDER BY t, month;
