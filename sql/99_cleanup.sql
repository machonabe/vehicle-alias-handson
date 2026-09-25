-- =====================================================================
-- 99_cleanup.sql  後片付け
-- ★ CASCADE は配下のテーブル・View・関数をすべて削除します。実行前に対象を必ず確認すること。
--   ノートブック版では 00_config の設定値（catalog / schema）を使って削除します（確認フラグあり）。
-- =====================================================================
-- @config-begin  ノートブック版では 00_config がカタログ・スキーマを設定するため、この範囲は自動で除去されます
USE CATALOG workspace;             -- ★ SQL エディタで実行する場合は config/00_config と同じ値にする
USE SCHEMA vehicle_alias_handson;  -- ★ 同上
-- @config-end

-- 削除対象の確認
-- 💡 仕組み：`run_sql()` が `IN カタログ.スキーマ` を付けて、00_config のスキーマの中の一覧を表示します（SQL エディタでは、選んでいるスキーマの一覧になります）。
SHOW TABLES;

-- 💡 なぜ：スキーマを削除すると、正規化関数（norm_code・norm_name）も一緒に削除されることを確かめます。
SHOW USER FUNCTIONS;

-- SQL エディタで削除する場合（スキーマ名を確認してからコメントを外して実行）
-- DROP SCHEMA IF EXISTS workspace.vehicle_alias_handson CASCADE;
