-- =============================================================
-- 「京游」智能行程规划产品 · 用户行为分析数据库
-- 数据库：MySQL 8.0+
-- 说明：三张核心表 —— 用户表(users)、埋点事件表(events)、订单表(orders)
-- 数据周期：2026-06-01 ~ 2026-08-31
-- =============================================================

CREATE DATABASE IF NOT EXISTS jingyou DEFAULT CHARSET utf8mb4;
USE jingyou;

-- ---------- 用户表 ----------
DROP TABLE IF EXISTS users;
CREATE TABLE users (
    user_id       INT          PRIMARY KEY COMMENT '用户ID',
    register_time DATETIME     COMMENT '注册时间',
    channel       VARCHAR(32)  COMMENT '获客渠道：自然流量/抖音信息流/小红书种草/微信分享裂变/高校地推',
    city_tier     VARCHAR(16)  COMMENT '城市线级',
    device        VARCHAR(16)  COMMENT '设备系统：iOS/Android',
    age           TINYINT      COMMENT '年龄'
) COMMENT='用户维度表';

-- ---------- 埋点事件表 ----------
-- 事件口径（对应「京游」核心用户路径）：
-- app_launch    启动小程序
-- ai_plan       输入需求/选择主题标签，发起AI行程规划
-- view_spot     查看景点/行程详情页
-- add_favorite  收藏景点
-- create_order  提交订单（门票/酒店/一日游套餐）
-- pay_order     支付成功
DROP TABLE IF EXISTS events;
CREATE TABLE events (
    session_id  INT          COMMENT '会话ID（同一场启动内的行为归为一个会话）',
    user_id     INT          COMMENT '用户ID',
    event_time  DATETIME     COMMENT '事件时间',
    event_name  VARCHAR(32)  COMMENT '事件名',
    channel     VARCHAR(32)  COMMENT '渠道（冗余字段，便于取数）',
    INDEX idx_session (session_id),
    INDEX idx_user_time (user_id, event_time),
    INDEX idx_event (event_name, event_time)
) COMMENT='用户行为埋点事件表';

-- ---------- 订单表 ----------
DROP TABLE IF EXISTS orders;
CREATE TABLE orders (
    order_id     INT          PRIMARY KEY,
    user_id      INT          COMMENT '用户ID',
    create_time  DATETIME     COMMENT '下单时间',
    product_type VARCHAR(32)  COMMENT '产品类型：景点门票/酒店预订/一日游套餐',
    amount       DECIMAL(10,2) COMMENT '订单金额(元)',
    is_paid      TINYINT      COMMENT '是否支付成功 1/0',
    is_refunded  TINYINT      COMMENT '是否退款 1/0',
    channel      VARCHAR(32)  COMMENT '渠道',
    INDEX idx_user (user_id),
    INDEX idx_time (create_time)
) COMMENT='订单表';

-- ---------- 数据导入（MySQL 8.0，按需修改文件路径） ----------
LOAD DATA INFILE '/your_path/users.csv'  INTO TABLE users
  FIELDS TERMINATED BY ',' ENCLOSED BY '"' LINES TERMINATED BY '\n' IGNORE 1 ROWS;

LOAD DATA INFILE '/your_path/events.csv' INTO TABLE events
  FIELDS TERMINATED BY ',' ENCLOSED BY '"' LINES TERMINATED BY '\n' IGNORE 1 ROWS
  (session_id, user_id, event_time, event_name, channel);

LOAD DATA INFILE '/your_path/orders.csv' INTO TABLE orders
  FIELDS TERMINATED BY ',' ENCLOSED BY '"' LINES TERMINATED BY '\n' IGNORE 1 ROWS;

-- 若本机导入遇到 secure_file_priv 限制，可用：
--   SHOW VARIABLES LIKE 'secure_file_priv';
-- 将 CSV 放入该目录，或改用 mysql 客户端的 LOAD DATA LOCAL INFILE。
