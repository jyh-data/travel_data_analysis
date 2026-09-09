# -*- coding: utf-8 -*-
"""
「智游北京」智能行程规划产品 · 用户行为分析脚本（Python 部分）
作者：纪语恒

分工：RFM 分层和复购分析在 SQL 里做（见 02_核心分析SQL.sql 的 Q5/Q7），
Python负责北极星、漏斗、渠道质量、留存、产品结构五部分。

用法：在仓库根目录运行  python 03_Pandas数据分析.py
默认读 data/ 目录里的全量数据（users.csv / events.csv / orders.csv）。
"""
import pandas as pd

# ---------- 0. 数据加载 ----------
USER_CSV  = "data/users.csv"
EVENT_CSV = "data/events.csv"
ORDER_CSV = "data/orders.csv"

users = pd.read_csv(USER_CSV,  parse_dates=["register_time"])
ev    = pd.read_csv(EVENT_CSV, parse_dates=["event_time"])
od    = pd.read_csv(ORDER_CSV, parse_dates=["create_time"])

# ---------- 1. 北极星指标：周活跃规划用户（WAU-Plan） ----------
# 按周聚合（周一起算，和 SQL 里 %x-%v 的 ISO 周口径一致）
plan = ev[ev.event_name == "ai_plan"].copy()
plan["week"] = plan.event_time.dt.to_period("W").dt.start_time
north = plan.groupby("week").user_id.nunique()
print("【北极星指标】周活跃规划用户：\n", north)

# ---------- 2. AARRR 会话级漏斗 ----------
# 每个环节统计"发生过该事件的会话数"，session_id 去重
stages = ["app_launch", "ai_plan", "view_spot", "add_favorite", "create_order", "pay_order"]
sv = [ev.loc[ev.event_name == s, "session_id"].nunique() for s in stages]
print("【漏斗】各环会话数：", dict(zip(stages, sv)))
print("【漏斗】启动→支付整体转化：{:.1f}%".format(sv[-1] / sv[0] * 100))
print("【漏斗】规划→详情流失：{:.1f}%".format((1 - sv[2] / sv[1]) * 100))

# ---------- 3. 渠道质量诊断 ----------
ch = ev.groupby("channel").agg(会话数=("session_id", "nunique"))
ch["规划率"] = ev[ev.event_name == "ai_plan"].groupby("channel").session_id.nunique() / ch["会话数"] * 100
ch["支付率"] = ev[ev.event_name == "pay_order"].groupby("channel").session_id.nunique() / ch["会话数"] * 100

net = od[(od.is_paid == 1) & (od.is_refunded == 0)]          # 净成交订单
ch["净GMV"] = net.groupby("channel").amount.sum()
ch["退款率"] = od[od.is_paid == 1].groupby("channel").is_refunded.mean() * 100
print("【渠道质量】\n", ch.round(2))

# ---------- 4. 留存分析（注册周 Cohort） ----------
# 先算每个用户的首次活跃日 d0，再按 d0 所在周分组，看第 N 天还有多少人回来
launch = ev[ev.event_name == "app_launch"].copy()
launch["date"] = launch.event_time.dt.normalize()
first = launch.groupby("user_id")["date"].min().rename("d0")

m = launch.merge(first, on="user_id")
m["day_n"] = (m["date"] - m["d0"]).dt.days
m["cohort"] = m["d0"].dt.to_period("W").dt.start_time

cohort = m.groupby(["cohort", "day_n"]).user_id.nunique().unstack()   # 行=注册周，列=第N天
retention = cohort.div(cohort[0], axis=0)                             # 除以基数 = 留存率

# 汇总的次留/7留/30留：先算每个注册周的留存率再取平均（和 SQL Q4 汇总口径一致）。
# 只统计"整周都有完整 N 天观察窗"的注册周——数据只到 2026-08-31，
# 比如最后一周注册的连次日都未必能观察到，算进来会把留存拉低。
# 注意 fillna(0)：某个注册周如果第 N 天一个人都没回来，透视表里是 NaN，
# 直接 mean() 会把这一周跳过（等于从分母里消失），填 0 才是"该周留存 0%"
end = launch["date"].max()
r1  = retention.loc[retention.index <= end - pd.Timedelta(days=7),  1].fillna(0).mean()
r7  = retention.loc[retention.index <= end - pd.Timedelta(days=13), 7].fillna(0).mean()
r30 = retention.loc[retention.index <= end - pd.Timedelta(days=36), 30].fillna(0).mean()
print("【留存】平均次留 {:.1f}% | 7留 {:.1f}% | 30留 {:.1f}%".format(r1 * 100, r7 * 100, r30 * 100))

# ---------- 5. 产品结构 ----------
prod = od.groupby("product_type").agg(订单量=("order_id", "count"), 客单价=("amount", "mean"))
prod["净GMV"] = net.groupby("product_type").amount.sum()
prod["退款率"] = od[od.is_paid == 1].groupby("product_type").is_refunded.mean() * 100
print("【产品结构】\n", prod.round(2))
