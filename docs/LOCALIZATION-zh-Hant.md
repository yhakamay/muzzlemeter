# Traditional Chinese (zh-Hant) terminology

Muzzlemeter's Traditional Chinese strings target **Taiwan**. Acetech is a Taiwanese
company, so Taiwanese airsoft players are a primary audience for an AC6000 companion
app, and the wording should read like a Taiwanese shop or field posting — not like a
Japanese UI transliterated character by character, and not like Mainland (zh-Hans)
technical writing converted to traditional glyphs.

None of the maintainers is a native speaker. The choices below were settled from
public Taiwanese sources: Acetech's own zh-Hant store, Taiwanese airsoft retailers,
the zh-tw Wikipedia article on the sport, and Taiwanese player forums/blogs. Each row
records what we picked, what we rejected, and the source that decided it. **If you
change one of these, add your source here too.**

Locale note: `zh-Hant` is used as a single Traditional Chinese locale. Hong Kong
usage overlaps heavily for this vocabulary (氣槍 rather than 生存遊戲 for the hobby
is the main divergence), but Taiwan is the tie-breaker.

## Settled terms

| Concept | Chosen | Rejected | Why / source |
| --- | --- | --- | --- |
| The hobby | 生存遊戲 | 野戰, 氣槍 | Every Taiwanese retailer brands itself this way, and it is the zh-tw Wikipedia article title. 野戰 is used (the Bahamut board is 野戰(生存)遊戲) but reads as the older/parallel name. https://zh.wikipedia.org/zh-tw/生存遊戲_(射擊運動) |
| The device | 測速器 | 彈速計, 初速計, 測速機, 初速機 | Acetech's own Traditional Chinese storefront files the AC6000 under 測速器. Taiwanese shops use 測速器 / 測速機 / 初速機 interchangeably; matching the manufacturer is the safest anchor. https://www.acetk.com/zh-hant/categories/測速器 |
| Muzzle velocity | 初速 | 彈速, 槍口初速 | Universal in Taiwanese listings and player writing — the joule calculators at both KUI and AOG label the input field exactly `初速(m/s)`. 槍口初速 is the formal long form, too heavy for a UI label. https://www.kui.com.tw/joule.php · https://www.aog.com.tw/shop.php?html=joule |
| BB weight | BB 彈重 | BB 彈重量, 彈重量 | Both Taiwanese joule calculators label the field `彈重(g)`. 彈重 is what players write; `BB` is kept as a disambiguating prefix. Same sources as above. |
| Energy | 動能 | 能量 | Taiwanese sources consistently say 槍口動能 / 動能焦耳, and the retailer calculators output `動能焦耳`. 能量 is not wrong but is not the term of art. |
| Joule | 焦耳 | 焦, 焦爾 | Standard, and used by the retailers and zh-tw Wikipedia. |
| Energy limit | 動能上限 | 能量上限, 焦耳限制, 限速 | Fields in Taiwan usually post a **velocity** limit (限速, in m/s with 0.2 g), so there is no single established phrase for a joule cap. 動能上限 composes from the vocabulary players already use (槍口動能) and stays correct for a J value. |
| Headroom under the limit | 餘量 | 餘裕 | 餘裕 is in the Taiwan MOE dictionary but means abundance of time/money — abstract leeway, not a measured remainder; as a label on `0.12 J` it reads as a Japanese loan. https://www.moedict.tw/餘裕 |
| Within-limit badge | 正常 | 餘裕, 安全 | The badge is a status tier next to 接近 / 超標, so the trio 正常 → 接近 → 超標 reads naturally. 安全 was rejected as over-claiming: the badge only reports the energy limit. |
| Near-limit badge ("Close") | 接近 | 注意, 警告 | Kept from the original translation. Describes the actual condition (close to the limit) rather than a generic caution. |
| Over-limit badge | 超標 | 超速, 超過 | 超標 covers exceeding a posted standard of any kind, which is what a joule cap is. 超速 would imply a velocity limit specifically. |
| Rate of fire | 射速 | 連發速度, 連射速度 | 射速 is the term throughout Taiwanese airsoft. The Yahoo Auctions listing for this very device (AC6000BT, official Taiwanese distributor) advertises it as 「測初速 射速」. Taiwanese player blogs use 射速 for RPM/RPS. https://tw.bid.yahoo.com/item/100763262187 · https://foxyairsofter.blogspot.com/2020/06/foxy2020.html |
| Extreme spread | 全距 | 極差 | Both denote max − min, but 全距 is the Taiwanese textbook term (NTU statistics course material; it is the zh-tw Wikipedia article title), while 極差 is the Mainland-preferred term (Baidu Baike headword). https://zh.wikipedia.org/zh-tw/全距 · http://homepage.ntu.edu.tw/~huilin/2008-1/ch4.pdf |
| Standard deviation | 標準差 | 標準偏差 | 標準差 is standard in Taiwan; 標準偏差 is the Japanese form. Kept from the original translation. Sample SD is 樣本標準差. Same NTU source. |
| Hop-up | Hop | HOP, 홉, 上旋 | Left in Latin script. Taiwanese players write it in Latin letters (HOP, HOP UP, HOP皮) and never translate it; casing varies, so the app's `Hop` is within normal usage. https://forum.gamer.com.tw/C.php?bsn=60534&snA=6778 |
| Inner barrel | 內管 | 內管 (unchanged) | Confirmed: Taiwanese review titles quote barrel length as 「內管175mm」. https://www.youtube.com/watch?v=NxS46arDGt0 |
| AEG | 電動 | 電動（AEG）, 電槍 | Retailer category is 電動槍; in the app the word sits in a power-source picker beside 瓦斯 / 手拉空氣, so the bare 電動 is parallel and unambiguous. The `（AEG）` gloss was dropped because no sibling option carries one. https://www.kui.com.tw/category/A1282SO |
| Gas | 瓦斯 | 氣動 | Taiwanese retailer category is 瓦斯槍. (zh-tw Wikipedia's formal 氣動槍 is not what shops or players say.) Same source. |
| Green gas | 綠瓦斯 | — | Standard Taiwanese name for HFC134a-based gas. |
| Spring / air-cocking | 手拉空氣 | 手拉（空氣）, 彈簧槍, 扣氣槍 | Every major Taiwanese retailer has a 手拉空氣槍 category. 扣氣槍 is specifically Tokyo Marui's own coinage; 彈簧槍 is the encyclopedic term. https://www.kui.com.tw/category/A2262SO |
| HPA | HPA | 高壓空氣系統 | Left as the acronym, as Taiwanese players write it. The long form appears only in encyclopedic text. |
| CO2 | CO2 | — | Retailer category is `CO2動力`; the bare acronym is what players write. |
| Manufacturer | 廠牌 | 製造商 | 廠牌 is what Taiwanese airsoft writing uses for a replica's brand (e.g. the Bahamut beginners' guide 「Airsoft各廠牌入門介紹」). 製造商 is correct but corporate. https://forum.gamer.com.tw/Co.php?bsn=60534&sn=2316 |
| Tokyo Marui | 馬牌 MARUI | 東京丸井, 東京マルイ, Tokyo Marui | Taiwanese shops list the brand as 「日本 MARUI 馬牌」/「TOKYO MARUI 馬牌」 — 馬牌 is the everyday Taiwanese nickname. 東京丸井 appears in zh-tw Wikipedia but is not what a player would type into a brand field. Used in the manufacturer placeholder. https://www.kui.com.tw/P0A9377S2O3/ |
| "Next-Gen" (Marui line) | 次世代 | (was localized away to `M4A1`) | 次世代 is used verbatim by Taiwanese retailers for Marui's Next-Generation series, so the model placeholder can keep the Japanese source's meaning. https://www.aog.com.tw/shop.php?id=58217 |
| Measuring / to measure | 測量 | 計測 | 計測 is a Japanese word, not Traditional Chinese; Taiwan uses 測量 (or 量測 in engineering registers). This was a leak from the Japanese source strings. |
| Session (one measuring run) | 紀錄 | 場次, 這次測試 | Kept. 場次 suggests a game round rather than a chronograph run, and the app already reads naturally as 本次紀錄 / 這筆紀錄. Distinct from the device log now that the log is 測速器日誌 (see below). |
| Device's internal log | 測速器日誌 | 主機日誌 | Unified with 測速器 elsewhere. 主機 in Taiwanese usage means a host machine or desktop tower, which is misleading for a handheld chronograph. This string is also used as the tag applied to imported sessions, so the tag and the sentence that quotes it were changed together. |
| Gun profile | 設定檔 | 描述檔, 配置檔 | 設定檔 is the ordinary Taiwanese term. (Apple's 描述檔 is reserved for MDM configuration profiles; 配置文件 is Mainland.) |
| Field / venue | 場地 | 靶場 | 場地 for the game venue; 靶場 kept where the source means a shooting range. |
| Shot count | 發 | 顆 | Taiwanese airsoft counts rounds as 發. |

## Conventions kept from the original translation

These were reviewed and left alone; they already match Taiwanese usage.

- Apple platform vocabulary: 小工具 (widget), 主畫面, 鎖定畫面, 動態島, 靜音開關,
  觸覺回饋, 藍牙.
- Taiwan-side IT vocabulary rather than Mainland equivalents: 匯入/匯出 (not 導入/導出),
  資料 (not 数据), 搜尋 (not 搜索), 預設值 (not 默认值), 裝置 (not 设备),
  連線 (not 连接), 儲存 (not 保存), 篩選, 螢幕.
- 交握 for "handshake" (Taiwanese CS usage; Mainland says 握手).
- 極端值 for outlier, 散布圖 for scatter plot, 離散程度 for dispersion.
- 橘色 for orange (Taiwan) rather than 橙色.
- 晴時多雲 for the weather example (Taiwan CWA phrasing).

## Open questions

- **Energy limit phrasing.** Taiwanese fields post velocity caps (限速, m/s at 0.2 g)
  far more often than joule caps, so 動能上限 is a composed term rather than an
  attested field posting. If a Taiwanese player reports that fields say something
  else (e.g. 焦耳限制), prefer their wording.
- **Hop casing.** `Hop`, `HOP` and `HOP UP` all occur in Taiwanese writing. `Hop`
  was kept for visual consistency with the rest of the UI; a native reviewer may
  prefer all-caps `HOP`.
- No Taiwanese review has been done on sentence rhythm, only on terminology.
