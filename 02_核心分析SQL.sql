-- =============================================================
-- 「京游」核心分析 SQL 集
-- 覆盖：北极星指标 / AARRR漏斗 / 渠道ROI / 留存Cohort / RFM分层 /
--       环比异动归因 / 复购分析 / 产品结构
-- 数据库：MySQL 8.0+（使用 CTE 与窗口函数）
-- 设计原则：每条 SQL 对应一个真实业务问题，注释里写的是"为什么这么做"
-- =============================================================
USE jingyou;

-- -------------------------------------------------------------
-- 0. 北极星指标：周活跃规划用户（WAU-Plan）+ 周环比
--    LAG() 取上一周的值算环比，用于监控增长趋势
-- -------------------------------------------------------------
WITH weekly AS (
  SELECT DATE_FORMAT(event_time, '%x-%v') AS week_no,
         COUNT(DISTINCT user_id)          AS wau_plan
  FROM events
  WHERE event_name = 'ai_plan'
  GROUP BY week_no
)
SELECT week_no,
       wau_plan,
       LAG(wau_plan) OVER (ORDER BY week_no)                          AS last_week,
       ROUND((wau_plan / LAG(wau_plan) OVER (ORDER BY week_no) - 1) * 100, 1) AS wow_pct
FROM weekly
ORDER BY week_no;

-- -------------------------------------------------------------
-- 1. 整体漏斗（会话级口径）
--    COUNT(DISTINCT CASE WHEN ...)：只对满足条件的行去重计数
-- -------------------------------------------------------------
SELECT
  COUNT(DISTINCT CASE WHEN event_name='app_launch'   THEN session_id END) AS 启动,
  COUNT(DISTINCT CASE WHEN event_name='ai_plan'      THEN session_id END) AS AI规划,
  COUNT(DISTINCT CASE WHEN event_name='view_spot'    THEN session_id END) AS 浏览详情,
  COUNT(DISTINCT CASE WHEN event_name='add_favorite' THEN session_id END) AS 收藏,
  COUNT(DISTINCT CASE WHEN event_name='create_order' THEN session_id END) AS 下单,
  COUNT(DISTINCT CASE WHEN event_name='pay_order'    THEN session_id END) AS 支付
FROM events;

-- -------------------------------------------------------------
-- 2. 分渠道漏斗：识别"量大利薄"渠道
-- -------------------------------------------------------------
SELECT channel,
  COUNT(DISTINCT session_id) AS 会话数,
  COUNT(DISTINCT CASE WHEN event_name='ai_plan'   THEN session_id END) AS 规划会话,
  COUNT(DISTINCT CASE WHEN event_name='pay_order' THEN session_id END) AS 支付会话,
  ROUND(COUNT(DISTINCT CASE WHEN event_name='pay_order' THEN session_id END)
      / COUNT(DISTINCT session_id) * 100, 2) AS 会话支付转化率_pct
FROM events
GROUP BY channel
ORDER BY 会话支付转化率_pct DESC;

-- -------------------------------------------------------------
-- 3. 渠道 ROI：注册量 / 付费转化 / 净GMV / 退款率
-- -------------------------------------------------------------
SELECT u.channel,
       COUNT(DISTINCT u.user_id)                                       AS 注册用户数,
       COUNT(DISTINCT o.user_id)                                       AS 付费用户数,
       ROUND(COUNT(DISTINCT o.user_id)/COUNT(DISTINCT u.user_id)*100, 2) AS 注册付费转化_pct,
       ROUND(SUM(CASE WHEN o.is_paid=1 AND o.is_refunded=0 THEN o.amount ELSE 0 END), 0) AS 净GMV,
       ROUND(SUM(CASE WHEN o.is_paid=1 AND o.is_refunded=1 THEN 1 ELSE 0 END)
           / SUM(o.is_paid) * 100, 2)                                  AS 退款率_pct
FROM users u
LEFT JOIN orders o ON u.user_id = o.user_id
GROUP BY u.channel
ORDER BY 净GMV DESC;

-- -------------------------------------------------------------
-- 4. 留存分析（Cohort）
--    思路：先算每个用户首次活跃日 d0 → 连接事件表算间隔天数 → 条件计数
-- -------------------------------------------------------------
WITH first_day AS (
  SELECT user_id, MIN(DATE(event_time)) AS d0
  FROM events
  WHERE event_name = 'app_launch'
  GROUP BY user_id
)
SELECT f.d0 AS cohort_date,
       COUNT(DISTINCT e.user_id) AS 新增活跃,
       ROUND(COUNT(DISTINCT IF(DATEDIFF(DATE(e.event_time), f.d0)=1,  e.user_id, NULL)) / COUNT(DISTINCT e.user_id)*100, 1) AS 次日留存,
       ROUND(COUNT(DISTINCT IF(DATEDIFF(DATE(e.event_time), f.d0)=7,  e.user_id, NULL)) / COUNT(DISTINCT e.user_id)*100, 1) AS 七日留存,
       ROUND(COUNT(DISTINCT IF(DATEDIFF(DATE(e.event_time), f.d0)=30, e.user_id, NULL)) / COUNT(DISTINCT e.user_id)*100, 1) AS 三十日留存
FROM first_day f
JOIN events e ON e.user_id = f.user_id AND e.event_name = 'app_launch'
GROUP BY f.d0
ORDER BY f.d0;

-- -------------------------------------------------------------
-- 5. RFM 付费用户分层（NTILE 三分位）
--    NTILE(3) 把用户按指标切成三档：R 越小越好(升序)，F/M 越大越好(降序)
-- -------------------------------------------------------------
WITH rfm AS (
  SELECT user_id,
         DATEDIFF('2026-09-01', MAX(create_time)) AS R,
         COUNT(*)                                 AS F,
         SUM(amount)                              AS M
  FROM orders
  WHERE is_paid = 1 AND is_refunded = 0
  GROUP BY user_id
),
score AS (
  SELECT *,
         -- 加次要排序键消除同值随机分配，保证结果可复现
         NTILE(3) OVER (ORDER BY R ASC,  M DESC, user_id) AS r_q,   -- R 第1档 = 最近消费
         NTILE(3) OVER (ORDER BY F DESC, M DESC, user_id) AS f_q,
         NTILE(3) OVER (ORDER BY M DESC, user_id)         AS m_q
  FROM rfm
)
SELECT
  CASE
    WHEN r_q=1 AND f_q=1 AND m_q=1 THEN '重要价值用户'
    WHEN r_q=3 AND f_q=1           THEN '重要唤回用户'
    WHEN r_q=1 AND f_q>1           THEN '重要发展用户'
    ELSE '一般挽留用户'
  END AS 分层,
  COUNT(*) AS 用户数,
  ROUND(AVG(M), 1) AS 人均消费
FROM score
GROUP BY 分层
ORDER BY 人均消费 DESC;

-- -------------------------------------------------------------
-- 6. 异动归因：支付 UV 下滑时的排查
--    第一层：按天看环比；第二层：下滑日按渠道下钻
-- -------------------------------------------------------------
WITH daily AS (
  SELECT DATE(event_time) AS dt, channel,
         COUNT(DISTINCT CASE WHEN event_name='pay_order' THEN user_id END) AS pay_uv
  FROM events
  GROUP BY dt, channel
)
SELECT dt, channel, pay_uv,
       LAG(pay_uv) OVER (PARTITION BY channel ORDER BY dt)                AS prev_uv,
       ROUND((pay_uv / LAG(pay_uv) OVER (PARTITION BY channel ORDER BY dt) - 1) * 100, 1) AS dod_pct
FROM daily
WHERE dt >= '2026-08-20'
ORDER BY dt, channel;

-- -------------------------------------------------------------
-- 7. 复购分析：首单后 30 天内的复购率
--    LEAD() 取同一用户的下一单时间，判断复购间隔
-- -------------------------------------------------------------
WITH seq AS (
  SELECT user_id, create_time,
         LEAD(create_time) OVER (PARTITION BY user_id ORDER BY create_time) AS next_order_time,
         ROW_NUMBER()  OVER (PARTITION BY user_id ORDER BY create_time) AS order_seq
  FROM orders
  WHERE is_paid = 1
)
SELECT
  COUNT(CASE WHEN order_seq = 1 THEN 1 END) AS 首单用户数,
  ROUND(COUNT(CASE WHEN order_seq = 1 AND next_order_time IS NOT NULL
                    AND DATEDIFF(next_order_time, create_time) <= 30 THEN 1 END)
      / COUNT(CASE WHEN order_seq = 1 THEN 1 END) * 100, 1) AS 首单后30日复购率_pct
FROM seq;

-- -------------------------------------------------------------
-- 8. 产品结构：订单量 / 客单价 / 净GMV / 退款率
-- -------------------------------------------------------------
SELECT product_type,
       COUNT(*)                                            AS 订单量,
       ROUND(AVG(amount), 1)                               AS 客单价,
       ROUND(SUM(CASE WHEN is_paid=1 AND is_refunded=0 THEN amount ELSE 0 END), 0) AS 净GMV,
       ROUND(SUM(is_refunded) / SUM(is_paid) * 100, 2)     AS 退款率_pct
FROM orders
GROUP BY product_type
ORDER BY 净GMV DESC;
