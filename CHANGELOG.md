# Changelog

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
