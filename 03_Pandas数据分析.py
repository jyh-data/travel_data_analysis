# -*- coding: utf-8 -*-
"""
「京游」智能行程规划产品 · 用户行为分析脚本（Python 部分）
作者：纪语恒
依赖：pandas（只用基础语法：read_csv / groupby / merge / 透视）
说明：RFM 分层与复购分析由 SQL 完成（见 02_核心分析SQL.sql 的 Q5/Q7），
      Python 这里负责北极星、漏斗、渠道质量、留存、产品结构五块。
用法：python3 03_数据分析脚本.py（与 数据/ 目录同级运行）
"""
import pandas as pd

# ---------- 0. 数据加载 ----------
users = pd.read_csv("数据/users.csv", parse_dates=["register_time"])
ev    = pd.read_csv("数据/events.csv", parse_dates=["event_time"])
od    = pd.read_csv("数据/orders.csv", parse_dates=["create_time"])

# ---------- 1. 北极星指标：周活跃规划用户（WAU-Plan） ----------
plan = ev[ev.event_name == "ai_plan"].copy()
plan["week"] = plan.event_time.dt.to_period("W").dt.start_time
north = plan.groupby("week").user_id.nunique()
print("【北极星指标】周活跃规划用户：\n", north)

# ---------- 2. AARRR 会话级漏斗 ----------
# 思路：对每个环节，统计"发生过该事件的会话数"（session_id 去重）
stages = ["app_launch", "ai_plan", "view_spot", "add_favorite", "create_order", "pay_order"]
sv = [ev.loc[ev.event_name == s, "session_id"].nunique() for s in stages]
print("【漏斗】各环会话数：", dict(zip(stages, sv)))
print("【漏斗】启动→支付整体转化：{:.1f}%".format(sv[-1] / sv[0] * 100))

# ---------- 3. 渠道质量诊断 ----------
ch = ev.groupby("channel").agg(会话数=("session_id", "nunique"))
ch["规划率"] = ev[ev.event_name == "ai_plan"].groupby("channel").session_id.nunique() / ch["会话数"] * 100
ch["支付率"] = ev[ev.event_name == "pay_order"].groupby("channel").session_id.nunique() / ch["会话数"] * 100

net = od[(od.is_paid == 1) & (od.is_refunded == 0)]          # 净成交订单
ch["净GMV"] = net.groupby("channel").amount.sum()
ch["退款率"] = od[od.is_paid == 1].groupby("channel").is_refunded.mean() * 100
print("【渠道质量】\n", ch.round(2))

# ---------- 4. 留存分析（Cohort） ----------
# 思路：算出每个用户首次活跃日 → 合并回事件表 → 算间隔天数 → 按注册周透视
launch = ev[ev.event_name == "app_launch"].copy()
launch["date"] = launch.event_time.dt.normalize()
first = launch.groupby("user_id")["date"].min().rename("d0")

m = launch.merge(first, on="user_id")
m["day_n"] = (m["date"] - m["d0"]).dt.days
m["cohort"] = m["d0"].dt.to_period("W").dt.start_time

cohort = m.groupby(["cohort", "day_n"]).user_id.nunique().unstack()   # 行=注册周，列=第N天
retention = cohort.div(cohort[0], axis=0)                             # 除以基数 = 留存率
print("【留存】平均次留 {:.1f}% | 7留 {:.1f}% | 30留 {:.1f}%".format(
    retention[1].mean() * 100, retention[7].mean() * 100, retention[30].mean() * 100))

# ---------- 5. 产品结构 ----------
prod = od.groupby("product_type").agg(订单量=("order_id", "count"), 客单价=("amount", "mean"))
prod["净GMV"] = net.groupby("product_type").amount.sum()
prod["退款率"] = od[od.is_paid == 1].groupby("product_type").is_refunded.mean() * 100
print("【产品结构】\n", prod.round(2))
