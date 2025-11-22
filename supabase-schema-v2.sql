-- ============================================================
-- 무의식게임 가치토큰 시스템 Supabase 스키마 v2 (완전 재설계)
-- 프로젝트: xcnzbbmdhjdldzzypcuf
-- ============================================================

-- 1. 사용자 데이터 테이블
CREATE TABLE IF NOT EXISTS user_data (
    user_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    product TEXT,

    -- 누적 데이터 (절대 리셋 안됨)
    received INTEGER DEFAULT 0 CHECK (received >= 0),  -- 시즌 누적 받은 금액
    given INTEGER DEFAULT 0 CHECK (given >= 0),        -- 시즌 누적 보낸 금액

    -- 일간 데이터 (매일 자정 리셋)
    daily_received INTEGER DEFAULT 0 CHECK (daily_received >= 0),
    daily_given INTEGER DEFAULT 0 CHECK (daily_given >= 0),

    -- 주간 데이터 (매주 월요일 리셋)
    weekly_received INTEGER DEFAULT 0 CHECK (weekly_received >= 0),
    weekly_given INTEGER DEFAULT 0 CHECK (weekly_given >= 0),

    -- 월간 데이터 (매달 1일 리셋) - 새로 추가!
    monthly_received INTEGER DEFAULT 0 CHECK (monthly_received >= 0),
    monthly_given INTEGER DEFAULT 0 CHECK (monthly_given >= 0),

    -- 리셋 추적
    last_daily_reset DATE,
    last_weekly_reset DATE,
    last_monthly_reset DATE,

    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 2. 대기 중인 토큰 전송 테이블
CREATE TABLE IF NOT EXISTS pending_tokens (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    to_user_id TEXT NOT NULL REFERENCES user_data(user_id) ON DELETE CASCADE,
    from_user_id TEXT NOT NULL REFERENCES user_data(user_id) ON DELETE CASCADE,
    from_name TEXT NOT NULL,
    amount INTEGER NOT NULL CHECK (amount > 0),
    note TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 3. 활동 로그 테이블
CREATE TABLE IF NOT EXISTS activities (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id TEXT REFERENCES user_data(user_id) ON DELETE SET NULL,
    message TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- 인덱스
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_pending_tokens_to_user ON pending_tokens(to_user_id);
CREATE INDEX IF NOT EXISTS idx_pending_tokens_from_user ON pending_tokens(from_user_id);
CREATE INDEX IF NOT EXISTS idx_pending_tokens_created ON pending_tokens(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_activities_created ON activities(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_activities_user ON activities(user_id);

-- ============================================================
-- 트리거: updated_at 자동 갱신
-- ============================================================

CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS update_user_data_updated_at ON user_data;
CREATE TRIGGER update_user_data_updated_at
    BEFORE UPDATE ON user_data
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- ============================================================
-- 함수: 자동 리셋 체크 및 처리
-- ============================================================

CREATE OR REPLACE FUNCTION check_and_reset_periods(p_user_id TEXT)
RETURNS user_data AS $$
DECLARE
    v_user user_data;
    v_today DATE := CURRENT_DATE;
    v_monday DATE := DATE_TRUNC('week', CURRENT_DATE)::DATE;
    v_first_of_month DATE := DATE_TRUNC('month', CURRENT_DATE)::DATE;
BEGIN
    SELECT * INTO v_user FROM user_data WHERE user_id = p_user_id;

    -- 일간 리셋 체크
    IF v_user.last_daily_reset IS NULL OR v_user.last_daily_reset < v_today THEN
        UPDATE user_data
        SET daily_received = 0,
            daily_given = 0,
            last_daily_reset = v_today
        WHERE user_id = p_user_id;
    END IF;

    -- 주간 리셋 체크 (월요일마다)
    IF v_user.last_weekly_reset IS NULL OR v_user.last_weekly_reset < v_monday THEN
        UPDATE user_data
        SET weekly_received = 0,
            weekly_given = 0,
            last_weekly_reset = v_monday
        WHERE user_id = p_user_id;
    END IF;

    -- 월간 리셋 체크 (매달 1일마다)
    IF v_user.last_monthly_reset IS NULL OR v_user.last_monthly_reset < v_first_of_month THEN
        UPDATE user_data
        SET monthly_received = 0,
            monthly_given = 0,
            last_monthly_reset = v_first_of_month
        WHERE user_id = p_user_id;
    END IF;

    -- 업데이트된 데이터 반환
    SELECT * INTO v_user FROM user_data WHERE user_id = p_user_id;
    RETURN v_user;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 함수: pending 금액 계산 (항상 실시간 계산)
-- ============================================================

CREATE OR REPLACE FUNCTION get_pending_amount(p_user_id TEXT)
RETURNS INTEGER AS $$
BEGIN
    RETURN COALESCE(
        (SELECT SUM(amount) FROM pending_tokens WHERE to_user_id = p_user_id),
        0
    );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 함수: 토큰 받기 처리 (트랜잭션 안전)
-- ============================================================

CREATE OR REPLACE FUNCTION accept_pending_token(p_token_id UUID)
RETURNS JSON AS $$
DECLARE
    v_token pending_tokens;
    v_amount INTEGER;
BEGIN
    -- 토큰 정보 조회 및 삭제 (한 번에 처리)
    DELETE FROM pending_tokens
    WHERE id = p_token_id
    RETURNING * INTO v_token;

    IF NOT FOUND THEN
        RETURN json_build_object(
            'success', false,
            'error', 'Token not found'
        );
    END IF;

    v_amount := v_token.amount;

    -- user_data 업데이트 (모든 기간별 데이터 동시 업데이트)
    UPDATE user_data
    SET
        received = received + v_amount,
        daily_received = daily_received + v_amount,
        weekly_received = weekly_received + v_amount,
        monthly_received = monthly_received + v_amount
    WHERE user_id = v_token.to_user_id;

    -- 활동 로그 추가
    INSERT INTO activities (user_id, message)
    VALUES (
        v_token.to_user_id,
        format('%s님께 받은 %s만원 수령!', v_token.from_name, v_amount)
    );

    RETURN json_build_object(
        'success', true,
        'amount', v_amount,
        'from_name', v_token.from_name
    );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 함수: 전체 받기 처리
-- ============================================================

CREATE OR REPLACE FUNCTION accept_all_pending_tokens(p_user_id TEXT)
RETURNS JSON AS $$
DECLARE
    v_total_amount INTEGER;
    v_count INTEGER;
BEGIN
    -- 총 금액 계산
    SELECT COALESCE(SUM(amount), 0), COUNT(*)
    INTO v_total_amount, v_count
    FROM pending_tokens
    WHERE to_user_id = p_user_id;

    IF v_count = 0 THEN
        RETURN json_build_object(
            'success', false,
            'error', 'No pending tokens'
        );
    END IF;

    -- 모든 토큰 삭제
    DELETE FROM pending_tokens WHERE to_user_id = p_user_id;

    -- user_data 업데이트
    UPDATE user_data
    SET
        received = received + v_total_amount,
        daily_received = daily_received + v_total_amount,
        weekly_received = weekly_received + v_total_amount,
        monthly_received = monthly_received + v_total_amount
    WHERE user_id = p_user_id;

    -- 활동 로그 추가
    INSERT INTO activities (user_id, message)
    VALUES (
        p_user_id,
        format('%s만원 수령!', v_total_amount)
    );

    RETURN json_build_object(
        'success', true,
        'amount', v_total_amount,
        'count', v_count
    );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 뷰: 사용자 랭킹 (누적)
-- ============================================================

CREATE OR REPLACE VIEW user_rankings_total AS
SELECT
    user_id,
    name,
    product,
    received,
    given,
    ROW_NUMBER() OVER (ORDER BY received DESC) as rank
FROM user_data
ORDER BY received DESC;

-- ============================================================
-- 뷰: 사용자 랭킹 (주간)
-- ============================================================

CREATE OR REPLACE VIEW user_rankings_weekly AS
SELECT
    user_id,
    name,
    product,
    weekly_received as received,
    weekly_given as given,
    ROW_NUMBER() OVER (ORDER BY weekly_received DESC) as rank
FROM user_data
ORDER BY weekly_received DESC;

-- ============================================================
-- 뷰: 사용자 랭킹 (월간)
-- ============================================================

CREATE OR REPLACE VIEW user_rankings_monthly AS
SELECT
    user_id,
    name,
    product,
    monthly_received as received,
    monthly_given as given,
    ROW_NUMBER() OVER (ORDER BY monthly_received DESC) as rank
FROM user_data
ORDER BY monthly_received DESC;

-- ============================================================
-- Row Level Security (RLS) 활성화
-- ============================================================

ALTER TABLE user_data ENABLE ROW LEVEL SECURITY;
ALTER TABLE pending_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE activities ENABLE ROW LEVEL SECURITY;

-- user_data 정책
DROP POLICY IF EXISTS "Anyone can view user data" ON user_data;
DROP POLICY IF EXISTS "Users can update own data" ON user_data;

CREATE POLICY "Anyone can view user data"
    ON user_data FOR SELECT
    USING (true);

CREATE POLICY "Anyone can update user data"
    ON user_data FOR UPDATE
    USING (true)
    WITH CHECK (true);

-- pending_tokens 정책
DROP POLICY IF EXISTS "Anyone can view pending tokens" ON pending_tokens;
DROP POLICY IF EXISTS "Anyone can create pending tokens" ON pending_tokens;
DROP POLICY IF EXISTS "Users can delete own pending tokens" ON pending_tokens;

CREATE POLICY "Anyone can view pending tokens"
    ON pending_tokens FOR SELECT
    USING (true);

CREATE POLICY "Anyone can create pending tokens"
    ON pending_tokens FOR INSERT
    WITH CHECK (true);

CREATE POLICY "Anyone can delete pending tokens"
    ON pending_tokens FOR DELETE
    USING (true);

-- activities 정책
DROP POLICY IF EXISTS "Anyone can view activities" ON activities;
DROP POLICY IF EXISTS "Anyone can create activities" ON activities;

CREATE POLICY "Anyone can view activities"
    ON activities FOR SELECT
    USING (true);

CREATE POLICY "Anyone can create activities"
    ON activities FOR INSERT
    WITH CHECK (true);

-- ============================================================
-- 초기 데이터: 8명의 사용자 (모두 0으로 초기화)
-- ============================================================

-- 기존 데이터 삭제
TRUNCATE TABLE activities CASCADE;
TRUNCATE TABLE pending_tokens CASCADE;
DELETE FROM user_data;

-- 초기 사용자 생성
INSERT INTO user_data (user_id, name, product, last_daily_reset, last_weekly_reset, last_monthly_reset) VALUES
    ('taewook', '태욱', '비즈니스 실행 코칭', CURRENT_DATE, DATE_TRUNC('week', CURRENT_DATE)::DATE, DATE_TRUNC('month', CURRENT_DATE)::DATE),
    ('dowan', '도완', '유튜브 컨설팅 코칭', CURRENT_DATE, DATE_TRUNC('week', CURRENT_DATE)::DATE, DATE_TRUNC('month', CURRENT_DATE)::DATE),
    ('hayeon', '하연', '라이프사이클 코칭', CURRENT_DATE, DATE_TRUNC('week', CURRENT_DATE)::DATE, DATE_TRUNC('month', CURRENT_DATE)::DATE),
    ('euna', '은아', '자본주의 머니 코칭', CURRENT_DATE, DATE_TRUNC('week', CURRENT_DATE)::DATE, DATE_TRUNC('month', CURRENT_DATE)::DATE),
    ('ray', '래이', '우주머니액팅 코칭', CURRENT_DATE, DATE_TRUNC('week', CURRENT_DATE)::DATE, DATE_TRUNC('month', CURRENT_DATE)::DATE),
    ('saerom', '새롬', 'CRM 개발 코칭', CURRENT_DATE, DATE_TRUNC('week', CURRENT_DATE)::DATE, DATE_TRUNC('month', CURRENT_DATE)::DATE),
    ('jieun', '지은', '닐스 기획 코칭', CURRENT_DATE, DATE_TRUNC('week', CURRENT_DATE)::DATE, DATE_TRUNC('month', CURRENT_DATE)::DATE),
    ('jinseul', '진슬', '스레드 분석기 코칭', CURRENT_DATE, DATE_TRUNC('week', CURRENT_DATE)::DATE, DATE_TRUNC('month', CURRENT_DATE)::DATE);

-- ============================================================
-- 완료
-- ============================================================
