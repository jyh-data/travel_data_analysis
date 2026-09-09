-- =============================================================
-- 「智游北京」核心分析 SQL 集
-- 覆盖：北极星指标 / AARRR漏斗 / 渠道质量 / 留存Cohort / RFM分层 /
--       环比异动归因 / 复购分析 / 产品结构
-- 数据库：MySQL 8.0+（用到 CTE、窗口函数、条件聚合）
-- =============================================================
USE zhiyou;

-- -------------------------------------------------------------
-- Q0. 北极星指标：周活跃规划用户（WAU-Plan）+ 周环比
--     选"成功生成一条行程"当北极星：这是用户感知到产品价值的第一个瞬间，
--     前置于收藏、下单和分享。LAG() 取上一周的值算环比。
-- -------------------------------------------------------------
WITH weekly AS (
  SELECT DATE_FORMAT(event_time, '%x-%v') AS week_no,   -- ISO 周，周一起算
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
-- Q1. 整体漏斗（会话级口径）
--     每个环节统计"发生过该事件的会话数"，session_id 去重。
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
-- Q2. 分渠道漏斗：哪个渠道"量大利薄"
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
-- Q3. 渠道质量评估：注册量 / 付费转化 / 净GMV / 退款率
--     （没有投放成本数据，算不了 ROI，这里只看质量指标）
--     注意"付费用户数"要限定 is_paid=1，只下过单没支付的不算付费。
-- -------------------------------------------------------------
SELECT u.channel,
       COUNT(DISTINCT u.user_id)                                                     AS 注册用户数,
       COUNT(DISTINCT CASE WHEN o.is_paid = 1 THEN o.user_id END)                    AS 付费用户数,
       ROUND(COUNT(DISTINCT CASE WHEN o.is_paid = 1 THEN o.user_id END)
           / COUNT(DISTINCT u.user_id) * 100, 2)                                     AS 注册付费转化_pct,
       ROUND(SUM(CASE WHEN o.is_paid=1 AND o.is_refunded=0 THEN o.amount ELSE 0 END), 0) AS 净GMV,
       ROUND(SUM(CASE WHEN o.is_paid=1 AND o.is_refunded=1 THEN 1 ELSE 0 END)
           / SUM(o.is_paid) * 100, 2)                                                AS 退款率_pct
FROM users u
LEFT JOIN orders o ON u.user_id = o.user_id
GROUP BY u.channel
ORDER BY 净GMV DESC;

-- -------------------------------------------------------------
-- Q4. 留存分析（注册周 Cohort）
--     先算每个用户的首次活跃日 d0，再按 d0 所在周分组，
--     看第 1 / 7 / 30 天还有多少人回来。
-- -------------------------------------------------------------
WITH first_day AS (
  SELECT user_id, MIN(DATE(event_time)) AS d0
  FROM events
  WHERE event_name = 'app_launch'
  GROUP BY user_id
)
SELECT DATE_FORMAT(f.d0, '%x-%v') AS 注册周,
       COUNT(DISTINCT f.user_id)  AS 新增活跃,
       ROUND(COUNT(DISTINCT IF(DATEDIFF(DATE(e.event_time), f.d0)=1,  e.user_id, NULL)) / COUNT(DISTINCT f.user_id)*100, 1) AS 次日留存_pct,
       ROUND(COUNT(DISTINCT IF(DATEDIFF(DATE(e.event_time), f.d0)=7,  e.user_id, NULL)) / COUNT(DISTINCT f.user_id)*100, 1) AS 七日留存_pct,
       ROUND(COUNT(DISTINCT IF(DATEDIFF(DATE(e.event_time), f.d0)=30, e.user_id, NULL)) / COUNT(DISTINCT f.user_id)*100, 1) AS 三十日留存_pct
FROM first_day f
JOIN events e ON e.user_id = f.user_id AND e.event_name = 'app_launch'
GROUP BY 注册周
ORDER BY 注册周;

-- 汇总口径（和 Python 脚本输出的三个数字一一对应）：
-- 先算每个注册周的留存率，再取平均；
-- 只统计"整周都有完整 N 天观察窗"的注册周——数据只到 2026-08-31，
-- 比如最后一周注册的连次日都未必能观察到，算进来会把留存拉低。
WITH first_day AS (
  SELECT user_id, MIN(DATE(event_time)) AS d0
  FROM events
  WHERE event_name = 'app_launch'
  GROUP BY user_id
),
cohort AS (
  SELECT DATE_SUB(f.d0, INTERVAL WEEKDAY(f.d0) DAY) AS wk_start,   -- 所在周的周一
         COUNT(DISTINCT f.user_id) AS base,
         COUNT(DISTINCT IF(DATEDIFF(DATE(e.event_time), f.d0)=1,  e.user_id, NULL)) AS d1,
         COUNT(DISTINCT IF(DATEDIFF(DATE(e.event_time), f.d0)=7,  e.user_id, NULL)) AS d7,
         COUNT(DISTINCT IF(DATEDIFF(DATE(e.event_time), f.d0)=30, e.user_id, NULL)) AS d30
  FROM first_day f
  JOIN events e ON e.user_id = f.user_id AND e.event_name = 'app_launch'
  GROUP BY wk_start
)
SELECT ROUND(AVG(IF(wk_start <= '2026-08-24', d1/base, NULL))*100, 1) AS 次留_pct,
       ROUND(AVG(IF(wk_start <= '2026-08-17', d7/base, NULL))*100, 1) AS 七留_pct,
       ROUND(AVG(IF(wk_start <= '2026-07-26', d30/base, NULL))*100, 1) AS 三十留_pct
FROM cohort;

-- -------------------------------------------------------------
-- Q5. RFM 付费用户分层（NTILE 三分位）
--     R 越小越好（升序），F / M 越大越好（降序）。
--     踩过的坑：NTILE 遇到同值会随机分档，多跑几次结果会变，
--     所以排序键里加了 M 和 user_id 兜底，保证每次跑结果一样。
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
         NTILE(3) OVER (ORDER BY R ASC,  M DESC, user_id) AS r_q,   -- 第1档 = 最近消费
         NTILE(3) OVER (ORDER BY F DESC, M DESC, user_id) AS f_q,   -- 第1档 = 频次最高
         NTILE(3) OVER (ORDER BY M DESC, user_id)         AS m_q    -- 第1档 = 金额最高
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
-- Q6. 异动归因：支付 UV 下滑时的两层排查
--     第一层：全渠道每天的支付 UV 环比，定位是哪一天开始掉的；
--     第二层：拿着那天按渠道拆开，和前一天对比，看是谁拖下来的。
-- -------------------------------------------------------------
-- 第一层：按天看环比
WITH daily AS (
  SELECT DATE(event_time) AS dt,
         COUNT(DISTINCT CASE WHEN event_name='pay_order' THEN user_id END) AS pay_uv
  FROM events
  GROUP BY dt
)
SELECT dt, pay_uv,
       LAG(pay_uv) OVER (ORDER BY dt) AS prev_uv,
       ROUND((pay_uv / LAG(pay_uv) OVER (ORDER BY dt) - 1) * 100, 1) AS dod_pct
FROM daily
WHERE dt >= '2026-08-20'
ORDER BY dt;

-- 第二层：下滑日的渠道拆解（这里的日期换成第一层查出来的那天）
SELECT channel,
       COUNT(DISTINCT IF(DATE(event_time)='2026-08-25' AND event_name='pay_order', user_id, NULL)) AS 当日支付UV,
       COUNT(DISTINCT IF(DATE(event_time)='2026-08-24' AND event_name='pay_order', user_id, NULL)) AS 前日支付UV
FROM events
WHERE DATE(event_time) IN ('2026-08-24', '2026-08-25')
GROUP BY channel
ORDER BY 当日支付UV - 前日支付UV;

-- -------------------------------------------------------------
-- Q7. 复购分析：首单后 30 天内的复购率
--     LEAD() 取同一用户的下一单时间，和首单时间算间隔。
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
-- Q8. 产品结构：订单量 / 客单价 / 净GMV / 退款率
-- -------------------------------------------------------------
SELECT product_type,
       COUNT(*)                                            AS 订单量,
       ROUND(AVG(amount), 1)                               AS 客单价,
       ROUND(SUM(CASE WHEN is_paid=1 AND is_refunded=0 THEN amount ELSE 0 END), 0) AS 净GMV,
       ROUND(SUM(is_refunded) / SUM(is_paid) * 100, 2)     AS 退款率_pct
FROM orders
GROUP BY product_type
ORDER BY 净GMV DESC;
