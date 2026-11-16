# Changelog

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
