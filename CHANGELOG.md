# Changelog

## 1.2.0

### English
- World map heat: on a continent map the 10 best zones by XP per hour are tinted from red to green, each with a rank medal and its rate. Hover one for its total XP and time, click it to open the zone.
- World map route: on a zone map the next stops of your route are drawn as numbered points joined by lines, with a pin on the next stop and a line from you to it. Click a stop to set a waypoint. Both can be turned off in Settings > Guide.
- New look: every window is a parchment sheet in a teal frame with brass lines, with a framed title plate, brass dividers, slate progress bars, rank medals (gold, silver, bronze, iron) and new icons.
- Dark mode and opacity: Settings > General > Window look switches between parchment and dark (light text on slate paper) and sets the window opacity (30-100%; parchment stays at 60% or more so the dark text stays readable). Changes apply right away.
- Guide tooltip: steps whose kill count comes from an item drop now list the item, how many are needed, the mob and its drop rate.
- Restart the game after updating (new files are not read by /reload).

### 한국어
- 세계 지도 효율 표시: 대륙 지도에서 시간당 경험치가 높은 지역 10곳을 빨강에서 초록까지 색칠하고, 순위 메달과 시간당 경험치를 표시합니다. 마우스를 올리면 총 경험치와 시간이 나오고, 클릭하면 그 지역 지도를 엽니다.
- 세계 지도 동선: 지역 지도에 동선의 다음 경유지를 번호와 선으로 그리고, 다음 경유지에 핀을 꽂고 내 위치에서 이어 줍니다. 경유지를 클릭하면 목적지를 표시합니다. 두 기능 모두 설정 > 가이드에서 끌 수 있습니다.
- 새 디자인: 모든 창을 청록 테두리와 놋쇠 선 안의 양피지로 바꾸고, 테두리가 있는 제목판, 놋쇠 구분선, 슬레이트 진행 바, 순위 메달(금·은·동·철)과 새 아이콘을 넣었습니다.
- 다크 모드와 불투명도: 설정 > 일반 > 창 모양에서 양피지와 다크(어두운 종이에 밝은 글자)를 고르고 창 불투명도(30~100%)를 정합니다. 양피지는 진한 글자가 잘 읽히도록 60% 아래로 내려가지 않습니다. 바꾸면 바로 적용됩니다.
- 안내 툴팁: 아이템 드랍으로 처치 수를 계산한 단계에 아이템, 필요 개수, 드랍 몬스터와 드랍률을 표시합니다.
- 업데이트 후에는 게임을 다시 시작하세요(새 파일은 /reload로 읽히지 않습니다).

## 1.1.1

### English
- Quest XP follows WoW Forever's rule: full reward up to 5 levels above the quest, 80% at 6, 60% at 7, and half from 8 on (classic went down to 10%). Grey quests already in your log count at half; grey quests not picked up yet are still skipped, since their mobs give no XP. Quest XP calibration taken with the old rule is reset once (kill calibration is kept).
- Quests in your log use the reward the game shows for them, and level-ups along the route lower it by the same rule.
- Quest log room: the route keeps track of how many quests you carry at once. When it would need more than your free log slots (40 minus what you hold), the least rewarding quests held at the fullest moment are left out, along with follow-ups that need them, and the route is planned again. The tooltip says how many were skipped.
- Fix: quests started by an item (often a chance drop from mobs) were counted as "available" before you had the item. They now count only once the item is in your bags.

### 한국어
- 퀘스트 경험치는 WoW Forever 규칙을 따릅니다. 퀘스트보다 5레벨 높을 때까지 100%, 6레벨 80%, 7레벨 60%, 8레벨 이상 50%입니다(클래식은 10%까지 줄었습니다). 퀘스트 목록에 이미 있는 회색 퀘스트는 50%로 계산하고, 아직 받지 않은 회색 퀘스트는 몬스터 경험치가 없어서 계속 뺍니다. 예전 규칙으로 쌓인 퀘스트 경험치 보정은 한 번 초기화됩니다(처치 보정은 유지).
- 퀘스트 목록에 있는 퀘스트는 게임이 보여 주는 보상값을 쓰고, 동선 중 레벨이 오르면 같은 규칙으로 줄입니다.
- 퀘스트 목록 자리: 동선을 따라 동시에 들고 있는 퀘스트 수를 계산합니다. 빈자리(40에서 지금 들고 있는 수를 뺀 값)보다 많이 필요하면, 가장 많이 차는 순간에 들고 있는 퀘스트 중 경험치가 낮은 것부터 빼고(그 퀘스트가 필요한 연계 퀘스트도 같이) 동선을 다시 짭니다. 툴팁에 몇 개를 뺐는지 나옵니다.
- 수정: 아이템으로 시작하는 퀘스트(몬스터가 확률로 떨구는 경우가 많음)를 아이템이 없어도 "받을 수 있음"으로 계산하던 문제를 고쳤습니다. 이제 아이템이 가방에 있을 때만 계산합니다.

## 1.1.0

### English
- Trips to other zones: quests whose mobs live elsewhere are grouped by destination and judged as one trip (their XP over fighting plus the round trip). A trip slower than the rest of the zone is left out of the score and the route, and the tooltip says how many quests were skipped and why ("not worth the trip"). Trips worth taking are done at the end of the zone, one journey per destination, with their turn-ins after it. Hubs with little work of their own, such as cities, keep all their trips.
- Follow-up quests: a follow-up whose earlier quest is not done in this zone (it lives elsewhere, is grey or elite, or was skipped as not worth the trip) can't be picked up on this route, so it is left out too and listed in the tooltip. A trip that unlocks follow-ups is judged by what the whole chain gives; if kept, the trip still happens at the end of the zone and the follow-ups come after it. Before, such a follow-up showed up as "Pick up" right away.
- Next-steps panel: a trip shows as one step naming the mobs and the zone to go to (e.g. "Kill Mob x8 | Other zone: Westfall"), instead of "Pick up" and "Turn in" back to back with nothing in between.
- Dungeon plan: quests done inside a dungeon (tagged "(Dungeon)" in the quest log, or whose mobs only live in instances) count only for dungeons you plan to run. Ctrl+click a zone in the list to plan or unplan its dungeons; the tooltip lists each dungeon with its quests and XP. A planned dungeon adds one "Dungeon: name" step (about 30 minutes) followed by its turn-ins. Dungeon names come from the quest log, so new WoW Forever dungeons work too. Saved per character.
- Reputation estimate: the zone tooltip lists the reputation its quests give or take per faction (largest first, losses in red), weighted like XP. Humans get +10% (Diplomacy). Kill reputation is not included, and the ranking is unchanged.
- Files: the Lua files moved into a `scripts` folder. Delete the old ZoneXPAdvisor folder before extracting if you update by hand, and restart the game (a /reload is not enough for new files).

### 한국어
- 다른 지역 이동: 잡을 몬스터가 다른 지역에 있는 퀘스트를 목적지별로 묶어서 한 번의 이동으로 계산합니다(경험치 ÷ 전투 시간과 왕복 시간). 지역의 나머지 퀘스트보다 시간당 효율이 낮은 이동은 점수와 동선에서 빼고, 툴팁에 몇 개를 왜 뺐는지("이동할 가치가 없어") 보여 줍니다. 할 만한 이동은 지역 동선 맨 끝에 목적지마다 한 번씩 다녀오고, 그 뒤에 보고합니다. 도시처럼 자체 퀘스트가 적은 거점은 이동을 모두 유지합니다.
- 연계 퀘스트: 앞 퀘스트를 이 지역에서 하지 않는 연계 퀘스트(앞 퀘스트가 다른 지역이거나, 회색·정예이거나, 이동할 가치가 없어 빠진 경우)는 이 동선에서 받을 수 없으므로 같이 빼고 툴팁에 표시합니다. 연계 퀘스트를 여는 이동은 연계 전체의 경험치로 판단하고, 유지할 때도 이동은 지역 동선 끝에 하고 연계 퀘스트는 그 뒤에 합니다. 전에는 이런 연계 퀘스트가 바로 "받기"로 나왔습니다.
- 다음 할 일 패널: 다른 지역 이동은 몬스터와 가야 할 지역을 알려 주는 한 단계로 보여 줍니다(예: "몬스터 x8 처치 | 다른 지역: 서부 몰락지대"). 전에는 그 사이 없이 "받기" 다음 바로 "보고"가 나왔습니다.
- 던전 계획: 던전 안에서 하는 퀘스트(퀘스트 목록에 "(던전)" 표시이거나 몬스터가 인스턴스 안에만 있는 퀘스트)는 방문하기로 정한 던전만 계산합니다. 목록에서 지역을 Ctrl+클릭하면 그 지역 던전을 방문 예정으로 바꾸거나 취소하고, 툴팁에 던전별 퀘스트 수와 경험치가 나옵니다. 방문 예정인 던전은 "던전: 이름" 단계 하나(약 30분)와 그 뒤의 보고 단계로 나옵니다. 던전 이름은 퀘스트 목록에서 가져오므로 WoW Forever 신규 던전도 됩니다. 캐릭터별로 저장합니다.
- 평판 예상: 지역 툴팁에 그 지역 퀘스트로 얻거나 잃는 평판을 진영별로 보여 줍니다(변화가 큰 순서, 잃는 평판은 빨간색). 경험치와 같은 가중치를 쓰고, 인간은 외교 특성으로 +10%를 더합니다. 몬스터 처치 평판은 포함하지 않으며 순위 계산은 바뀌지 않습니다.
- 파일 구성: Lua 파일을 `scripts` 폴더로 옮겼습니다. 직접 설치한다면 기존 ZoneXPAdvisor 폴더를 지우고 압축을 풀고, 게임을 다시 시작하세요(새 파일은 /reload로 읽히지 않습니다).

## 1.0.2

### English
- Mixed camps: kill and collect objectives within about 160 yards of each other are planned as one stop, also across quests, because you kill those mobs together. The route no longer splits one camp into separate steps with a turn-in squeezed in between. (Quests that unlock each other are kept apart, so the order stays valid.)
- Next-steps panel shows a camp on one line, e.g. "Kill Mob A x6, Mob B x3", with the quests it serves. Objectives of finished quests drop out of the line, and long lines are cut off instead of overlapping.
- Fix: quests picked up and turned in here whose mobs live in another zone (common in cities) were counted with no fighting time, so a city could top the XP-per-hour list with absurd rates. Those objectives now count their fighting time plus a round trip to that zone, shown in the zone tooltip.

### 한국어
- 혼합 캠프: 약 160야드 안에 모여 있는 처치·수집 목표는 다른 퀘스트 것이라도 한 경유지로 계산합니다. 실제로 그 몬스터들은 한 번에 같이 잡기 때문입니다. 이제 한 캠프가 여러 단계로 나뉘거나 그 사이에 보고가 끼어들지 않습니다. (서로 선행 관계인 퀘스트는 묶지 않아서 순서는 그대로 지켜집니다.)
- 다음 할 일 패널은 캠프를 한 줄로 보여 줍니다. 예: "몬스터 A x6, 몬스터 B x3 처치", 아랫줄에는 해당 퀘스트. 끝난 퀘스트의 목표는 줄에서 빠지고, 긴 줄은 다음 줄과 겹치지 않게 잘립니다.
- 수정: 이 지역에서 받고 보고하지만 잡을 몬스터는 다른 지역에 있는 퀘스트(도시에 많음)를 전투 시간 없이 계산해서, 도시가 터무니없는 시간당 경험치로 1위에 오르던 문제를 고쳤습니다. 이제 그 목표의 전투 시간과 그 지역까지 왕복 시간을 더하고, 지역 툴팁에 표시합니다.

## 1.0.1

### English
- Shorter quest routes: after 2-opt, an Or-opt pass moves single stops or short runs of stops to where they fit best (e.g. a lone pickup next to nearby stops), keeping pickup → objectives → turn-in order. Travel distance is about 10% shorter on average, and the next-steps order is more natural. Route planning is capped at 8 ms per zone so big zones never stall a frame.

### 한국어
- 더 짧은 퀘스트 동선: 2-opt 뒤에 Or-opt를 추가해서, 동떨어진 경유지 하나나 짧은 묶음을 더 잘 맞는 자리로 옮깁니다(받기 → 목표 → 보고 순서는 그대로). 이동 거리가 평균 10% 정도 줄고, 다음 할 일 순서가 더 자연스러워집니다. 큰 지역에서도 프레임이 끊기지 않도록 지역당 계산 시간을 8 ms로 제한합니다.

## 1.0.0

### English
- First stable release.
- Next-steps panel: shows the next 5 stops of the planned route in the zone you are in (quests to pick up, mobs to kill, items to collect, quests to turn in). Finished steps disappear as you play. Click a step to set a map waypoint (TomTom is used when installed). Open it with the "Next steps" button, /zxp next, or Settings → Guide.
- Session report: XP gained this session and XP per hour, split into quest XP and kill XP, per-zone time and XP per hour compared with the predicted rate, and the time to your next level at this pace. Time AFK is not counted; a new session starts after 30 minutes offline. Open it with the "Session" button or /zxp session.
- Move-on alert: a chat and on-screen message when your zone has little XP left, or another zone gives at least 1.5x the XP per hour. Not shown in towns, inns or instances, and the same advice is repeated at most every 15 minutes. Can be turned off in Settings → Guide.
- Zones are now re-checked in the background after quest, level and zone changes (at most every 45 seconds, never in combat or on a flight), so the panel, the alert and the minimap tooltip stay current with the window closed.
- New Settings tab "Guide".
- The zone you are in no longer drops down the list just because you finished some of its quests: the total XP sort subtracts the XP you would miss while travelling to each zone (the zone you stand in costs nothing), and the XP-per-hour sort lowers nearly finished zones step by step instead of dropping them to the bottom at once.

### 한국어
- 첫 정식 버전입니다.
- 다음 할 일 패널: 지금 있는 지역의 최적 동선에서 다음 5단계를 보여 줍니다. 받을 퀘스트, 잡을 몬스터, 모을 아이템, 보고할 퀘스트 순서입니다. 끝낸 단계는 플레이하면서 자동으로 사라지고, 클릭하면 지도에 목적지를 표시합니다(TomTom이 있으면 TomTom 사용). "다음 할 일" 버튼, /zxp next, 또는 설정 → 가이드에서 켤 수 있습니다.
- 세션 리포트: 이번 세션에 얻은 경험치와 시간당 경험치, 퀘스트/처치 경험치 비율, 지역별 시간과 시간당 경험치(예상값 대비), 지금 속도로 다음 레벨까지 걸리는 시간을 보여 줍니다. 자리 비움 시간은 빼고, 30분 넘게 접속하지 않으면 새 세션이 시작됩니다. "세션" 버튼이나 /zxp session 으로 엽니다.
- 이동 알림: 지금 지역에 남은 경험치가 적거나, 다른 지역의 시간당 경험치가 1.5배 이상이면 채팅과 화면 메시지로 알려 줍니다. 마을, 여관, 인스턴스에서는 알리지 않고, 같은 알림은 15분에 한 번만 나옵니다. 설정 → 가이드에서 끌 수 있습니다.
- 퀘스트, 레벨, 지역이 바뀌면 창을 닫아 둔 상태에서도 지역을 다시 계산합니다(최대 45초에 한 번, 전투 중이나 비행 중에는 하지 않음). 그래서 패널, 알림, 미니맵 툴팁이 항상 최신 상태로 유지됩니다.
- 설정에 "가이드" 탭 추가
- 지금 있는 지역의 퀘스트를 일부 끝냈다고 그 지역이 목록에서 갑자기 밀려나지 않습니다. 총 경험치 정렬은 각 지역까지 이동하는 동안 놓치는 경험치를 빼고(지금 있는 지역은 0), 시간당 경험치 정렬은 거의 끝난 지역을 한 번에 맨 아래로 보내지 않고 조금씩 낮춥니다.

## 0.6.0 (Beta)

### English
- Level-ups along the route: XP is now added up in the order the route earns it, and you level up on the way, so later quest rewards and kills give less (nothing once grey). The rested pool is spent as kills happen. Zones that take you up several levels no longer overstate their XP.
- Rows show the level you reach (e.g. "reaches Lv 25.3") instead of "x times the next level"; the tooltip shows the level after the zone's quests.
- Getting there: route time now includes travelling from where you stand to the zone (the faster of running and a flight path on the same continent, about 15 minutes for a boat or zeppelin trip). XP per hour counts it too.
- Assumes known flight paths; the hearthstone is not modelled.
- Language option in Settings → General: game language, English or 한국어 (applies after a UI reload). Quest and zone names still come from the game client.

### 한국어
- 동선 중 레벨업: 동선에서 퀘스트를 끝내는 순서대로 경험치를 쌓으며 레벨을 올려 계산합니다. 레벨이 오르면 뒤쪽 퀘스트 보상과 처치 경험치가 줄고, 회색이 되면 0이 됩니다. 휴식 경험치도 처치 순서대로 소모합니다. 몇 레벨씩 오르는 지역의 경험치가 부풀려지지 않습니다.
- 목록에 "다음 레벨의 N배" 대신 도착 레벨(예: "Lv 25.3 도달")을 보여주고, 툴팁에 퀘스트를 끝낸 뒤 레벨을 표시합니다.
- 지역까지 이동: 지금 위치에서 그 지역까지 가는 시간을 동선 시간에 더합니다. 같은 대륙은 뛰어가기와 비행 경로 중 빠른 쪽, 다른 대륙은 배/비행선으로 약 15분입니다. 시간당 경험치에도 반영됩니다.
- 비행 경로는 이미 알고 있다고 가정하며, 귀환석은 계산하지 않습니다.
- 설정 → 일반에 언어 선택 추가: 게임 언어 / English / 한국어 (UI를 다시 불러오면 적용). 퀘스트와 지역 이름은 게임 클라이언트 언어 그대로 나옵니다.

## 0.5.0 (Beta)

### English
- Rested XP: kill XP is doubled while you are rested, so each zone now gets the extra XP from its required kills, up to your rested pool. Shown in the zone tooltip.
- Elite and group quests are left out while you play solo (quests that need elite kills, or that suggest a group). They are counted in a group, or when enabled in Settings → Accuracy. The tooltip shows how many were left out, and counted ones are tagged [Elite].
- Item objectives prefer normal mobs over elites when both drop the item.
- XP calibration: quest turn-ins and solo kills of a targeted mob are compared with the predicted XP. After 3 turn-ins / 5 kills, the median difference corrects later estimates for that character.
- New Settings tab "Accuracy" with the elite option, your current rested XP and the calibration status (with a reset button).

### 한국어
- 휴식 경험치: 휴식 경험치가 있으면 처치 경험치가 2배가 되므로, 각 지역의 목표 몬스터 경험치에 남은 휴식 경험치만큼 더합니다. 지역 툴팁에 표시됩니다.
- 혼자 플레이할 때는 정예/파티 퀘스트(정예 몬스터를 잡아야 하거나 파티를 권장하는 퀘스트)를 계산에서 뺍니다. 파티 중이거나 설정 → 정확도에서 켜면 포함하며, 툴팁에 뺀 개수가 나오고 포함된 퀘스트에는 [정예]가 붙습니다.
- 아이템 목표는 일반 몬스터와 정예 몬스터가 모두 떨구면 일반 몬스터 기준으로 계산합니다.
- 경험치 보정: 퀘스트 보고와, 혼자서 대상으로 잡은 몬스터 처치 때 예상 경험치와 실제 경험치를 비교합니다. 퀘스트 3회 / 처치 5회가 쌓이면 그 차이의 중앙값으로 그 캐릭터의 이후 계산을 보정합니다.
- 설정에 "정확도" 탭 추가: 정예 퀘스트 옵션, 현재 휴식 경험치, 보정 상태(초기화 버튼 포함)

## 0.4.2 (Beta)

### English
- About tab: GitHub, CurseForge and Discord buttons. Clicking one shows the link ready to copy with Ctrl+C.

### 한국어
- 정보 탭에 GitHub, CurseForge, Discord 버튼을 추가했습니다. 누르면 Ctrl+C로 바로 복사할 수 있는 링크 창이 뜹니다.

## 0.4.1 (Beta)

### English
- Kill-time measurement now ignores time that isn't hunting:
  - Going AFK breaks the measurement.
  - Time with a vendor, mail, quest, gossip, trainer, auction, bank or flight-map window open is removed.
  - Standing still out of combat with full health and mana for more than 15 seconds is removed (resting to recover health or mana still counts).
  - Kills in towns and inns are skipped; kills in a group are skipped by default (toggle in settings).
- Settings → Kill time shows how much pause time was removed and how many kills were skipped.
- Tip: press "Clear measurements" once so older samples recorded before this filter are replaced.
- About tab links to the GitHub project page.

### 한국어
- 전투 시간 측정에서 사냥이 아닌 시간을 뺍니다:
  - 자리 비움(AFK) 상태가 되면 측정을 끊습니다.
  - 상인, 우편함, 퀘스트, 대화, 훈련사, 경매장, 은행, 비행 경로 창을 연 시간을 뺍니다.
  - 전투 밖에서 체력과 마나가 가득 찬 채로 15초 넘게 가만히 있던 시간을 뺍니다 (체력/마나 회복을 위한 휴식은 그대로 계산).
  - 마을과 여관에서 잡은 몬스터는 기록하지 않고, 파티 중 처치도 기본으로 건너뜁니다 (설정에서 변경 가능).
- 설정 → 전투 시간 탭에서 뺀 대기 시간과 건너뛴 기록 수를 보여줍니다.
- 팁: 이 필터가 생기기 전의 기록을 정리하려면 "측정 기록 지우기"를 한 번 눌러주세요.
- 정보 탭에 GitHub 프로젝트 링크를 추가했습니다.

## 0.4.0 (Beta)

First public release.

### English
- Zone ranking from your current XP, quest log and completed quests, for Alliance and Horde.
- Quest XP scaled to your level, plus XP from the kills your quests require (item drops estimated from drop rates).
- Hunting-ground rating per zone (good / fair / sparse).
- Optimized quest route with time and XP-per-hour estimates; sort by total XP or XP per hour.
- Kill time measured from your own play (median gap between kills in the same zone, last 60 kills, used after 20). Kills are detected from the game's death events, including AoE kills without a target; an XP-message method is available in settings.
- Minimap button (left-click: window, right-click: settings, Shift + left-click: sort, drag: move) and addon-compartment entry.
- Settings window with General, Kill time and About tabs.

### 한국어
- 현재 경험치, 퀘스트 로그, 완료한 퀘스트를 바탕으로 지역 순위를 보여줍니다 (얼라이언스/호드).
- 내 레벨에 맞춘 퀘스트 경험치와, 퀘스트 목표로 잡아야 하는 몬스터의 경험치를 계산합니다 (아이템 목표는 드롭률로 추정).
- 지역별 사냥터 등급 (좋음 / 보통 / 적음)
- 최적 퀘스트 동선과 소요 시간, 시간당 경험치. 총 경험치 순 또는 시간당 경험치 순 정렬
- 전투 시간 실측 (같은 지역 처치 간격의 중앙값, 최근 60마리, 20마리부터 적용). 게임의 사망 이벤트로 처치를 감지하며, 대상을 잡지 않은 광역 사냥도 포함합니다. 경험치 메시지 방식도 설정에서 고를 수 있습니다.
- 미니맵 버튼 (왼쪽 클릭: 창, 오른쪽 클릭: 설정, Shift + 왼쪽 클릭: 정렬, 드래그: 이동)과 애드온 메뉴 등록
- 일반 / 전투 시간 / 정보 탭이 있는 설정 창
