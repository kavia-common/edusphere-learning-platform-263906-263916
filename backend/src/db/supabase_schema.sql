-- Supabase LMS Schema: tables, enums, triggers, RLS policies
-- IMPORTANT: Run this in Supabase SQL editor (Project > SQL).
-- Notes:
-- - Do NOT expose service_role key on frontend; use it only on trusted backend.
-- - Realtime: Enable for chat_messages and announcements via Supabase Realtime UI.

-- =========================
-- Enums
-- =========================
create type public.user_role as enum ('student', 'teacher', 'admin');
create type public.submission_status as enum ('submitted', 'graded', 'returned');
create type public.assignment_type as enum ('file', 'text', 'quiz');

-- =========================
-- Tables
-- =========================
-- profiles linked to auth.users
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role public.user_role not null default 'student',
  full_name text,
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.courses (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text,
  teacher_id uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.enrollments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  course_id uuid not null references public.courses(id) on delete cascade,
  role public.user_role not null default 'student',
  created_at timestamptz not null default now(),
  unique (user_id, course_id)
);

create table if not exists public.modules (
  id uuid primary key default gen_random_uuid(),
  course_id uuid not null references public.courses(id) on delete cascade,
  title text not null,
  description text,
  position int not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists public.assignments (
  id uuid primary key default gen_random_uuid(),
  course_id uuid not null references public.courses(id) on delete cascade,
  module_id uuid references public.modules(id) on delete set null,
  title text not null,
  description text,
  due_at timestamptz,
  max_points int not null default 100,
  type public.assignment_type not null default 'file',
  created_at timestamptz not null default now()
);

create table if not exists public.submissions (
  id uuid primary key default gen_random_uuid(),
  assignment_id uuid not null references public.assignments(id) on delete cascade,
  student_id uuid not null references public.profiles(id) on delete cascade,
  content text, -- could be text answer or storage object path
  storage_path text, -- path in 'submissions' bucket when type = file
  status public.submission_status not null default 'submitted',
  grade int,
  feedback text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (assignment_id, student_id)
);

create table if not exists public.quizzes (
  id uuid primary key default gen_random_uuid(),
  course_id uuid not null references public.courses(id) on delete cascade,
  assignment_id uuid unique references public.assignments(id) on delete cascade,
  time_limit_minutes int,
  created_at timestamptz not null default now()
);

create table if not exists public.quiz_questions (
  id uuid primary key default gen_random_uuid(),
  quiz_id uuid not null references public.quizzes(id) on delete cascade,
  question_text text not null,
  options jsonb,         -- e.g., ["A","B","C","D"]
  correct_answer jsonb,  -- e.g., "A" or ["A","C"]
  points int not null default 1,
  position int not null default 0
);

create table if not exists public.quiz_attempts (
  id uuid primary key default gen_random_uuid(),
  quiz_id uuid not null references public.quizzes(id) on delete cascade,
  student_id uuid not null references public.profiles(id) on delete cascade,
  answers jsonb, -- map of question_id -> submitted_answer
  score int,
  started_at timestamptz not null default now(),
  submitted_at timestamptz,
  unique (quiz_id, student_id, started_at)
);

create table if not exists public.chat_messages (
  id bigint generated always as identity primary key,
  course_id uuid not null references public.courses(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  message text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.announcements (
  id uuid primary key default gen_random_uuid(),
  course_id uuid not null references public.courses(id) on delete cascade,
  teacher_id uuid not null references public.profiles(id) on delete cascade,
  title text not null,
  body text not null,
  created_at timestamptz not null default now()
);

-- Updated at triggers
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists set_profiles_updated_at on public.profiles;
create trigger set_profiles_updated_at before update on public.profiles
for each row execute function public.set_updated_at();

drop trigger if exists set_submissions_updated_at on public.submissions;
create trigger set_submissions_updated_at before update on public.submissions
for each row execute function public.set_updated_at();

-- =========================
-- Auth → Profiles auto-provision
-- Creates a profile row for every new auth user
-- =========================
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  meta_role text;
begin
  -- Try to read role from auth user metadata
  meta_role := coalesce(new.raw_user_meta_data->>'role', 'student');
  if meta_role not in ('student','teacher','admin') then
    meta_role := 'student';
  end if;

  insert into public.profiles (id, role, full_name, avatar_url)
  values (new.id, meta_role::public.user_role, new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'avatar_url');

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

-- =========================
-- Security: Enable Row Level Security
-- =========================
alter table public.profiles enable row level security;
alter table public.courses enable row level security;
alter table public.enrollments enable row level security;
alter table public.modules enable row level security;
alter table public.assignments enable row level security;
alter table public.submissions enable row level security;
alter table public.quizzes enable row level security;
alter table public.quiz_questions enable row level security;
alter table public.quiz_attempts enable row level security;
alter table public.chat_messages enable row level security;
alter table public.announcements enable row level security;

-- Helper: current user's role from profile
create or replace function public.current_user_role()
returns public.user_role language sql stable as $$
  select coalesce(
    (select role from public.profiles p where p.id = auth.uid()),
    'student'::public.user_role
  );
$$;

-- =========================
-- RLS Policies
-- Admins can do everything (service role bypasses RLS; but include explicit admin grants for clarity)
-- =========================

-- PROFILES
drop policy if exists profiles_self_select on public.profiles;
create policy profiles_self_select on public.profiles
for select using (id = auth.uid() or public.current_user_role() = 'admin');

drop policy if exists profiles_self_update on public.profiles;
create policy profiles_self_update on public.profiles
for update using (id = auth.uid() or public.current_user_role() = 'admin');

-- COURSES
drop policy if exists courses_read_by_enrolled_or_teacher on public.courses;
create policy courses_read_by_enrolled_or_teacher on public.courses
for select using (
  public.current_user_role() = 'admin'
  or teacher_id = auth.uid()
  or exists(select 1 from public.enrollments e where e.course_id = courses.id and e.user_id = auth.uid())
);

drop policy if exists courses_insert_by_teacher_admin on public.courses;
create policy courses_insert_by_teacher_admin on public.courses
for insert with check (
  public.current_user_role() in ('teacher','admin')
);

drop policy if exists courses_update_by_owner_or_admin on public.courses;
create policy courses_update_by_owner_or_admin on public.courses
for update using (
  public.current_user_role() = 'admin' or teacher_id = auth.uid()
);

-- ENROLLMENTS
drop policy if exists enrollments_read_by_related on public.enrollments;
create policy enrollments_read_by_related on public.enrollments
for select using (
  public.current_user_role() = 'admin'
  or user_id = auth.uid()
  or exists(select 1 from public.courses c where c.id = enrollments.course_id and (c.teacher_id = auth.uid()))
);

drop policy if exists enrollments_insert_by_admin_teacher on public.enrollments;
create policy enrollments_insert_by_admin_teacher on public.enrollments
for insert with check (
  public.current_user_role() in ('teacher','admin')
);

drop policy if exists enrollments_update_by_admin_teacher on public.enrollments;
create policy enrollments_update_by_admin_teacher on public.enrollments
for update using (public.current_user_role() in ('teacher','admin'));

-- MODULES
drop policy if exists modules_select_by_course_access on public.modules;
create policy modules_select_by_course_access on public.modules
for select using (
  public.current_user_role() = 'admin'
  or exists(select 1 from public.courses c where c.id = modules.course_id and (c.teacher_id = auth.uid()))
  or exists(select 1 from public.enrollments e where e.course_id = modules.course_id and e.user_id = auth.uid())
);

drop policy if exists modules_write_by_teacher_admin on public.modules;
create policy modules_write_by_teacher_admin on public.modules
for insert with check (
  public.current_user_role() in ('teacher','admin')
  and exists(select 1 from public.courses c where c.id = modules.course_id and (c.teacher_id = auth.uid() or public.current_user_role() = 'admin'))
);
create policy modules_update_by_teacher_admin on public.modules
for update using (
  public.current_user_role() = 'admin'
  or exists(select 1 from public.courses c where c.id = modules.course_id and c.teacher_id = auth.uid())
);

-- ASSIGNMENTS
drop policy if exists assignments_select_by_course_access on public.assignments;
create policy assignments_select_by_course_access on public.assignments
for select using (
  public.current_user_role() = 'admin'
  or exists(select 1 from public.courses c where c.id = assignments.course_id and (c.teacher_id = auth.uid()))
  or exists(select 1 from public.enrollments e where e.course_id = assignments.course_id and e.user_id = auth.uid())
);

drop policy if exists assignments_write_by_teacher_admin on public.assignments;
create policy assignments_write_by_teacher_admin on public.assignments
for insert with check (
  public.current_user_role() in ('teacher','admin')
  and exists(select 1 from public.courses c where c.id = assignments.course_id and (c.teacher_id = auth.uid() or public.current_user_role() = 'admin'))
);
create policy assignments_update_by_teacher_admin on public.assignments
for update using (
  public.current_user_role() = 'admin'
  or exists(select 1 from public.courses c where c.id = assignments.course_id and c.teacher_id = auth.uid())
);

-- SUBMISSIONS
drop policy if exists submissions_select_by_student_or_teacher on public.submissions;
create policy submissions_select_by_student_or_teacher on public.submissions
for select using (
  public.current_user_role() = 'admin'
  or student_id = auth.uid()
  or exists(
    select 1 from public.assignments a
    join public.courses c on c.id = a.course_id
    where a.id = submissions.assignment_id and c.teacher_id = auth.uid()
  )
);

drop policy if exists submissions_insert_by_student on public.submissions;
create policy submissions_insert_by_student on public.submissions
for insert with check (
  student_id = auth.uid()
  and exists(
    select 1 from public.assignments a
    join public.enrollments e on e.course_id = a.course_id and e.user_id = auth.uid()
    where a.id = submissions.assignment_id
  )
);

drop policy if exists submissions_update_by_teacher_or_owner on public.submissions;
create policy submissions_update_by_teacher_or_owner on public.submissions
for update using (
  public.current_user_role() = 'admin'
  or student_id = auth.uid() -- allow student to edit before graded/returned
  or exists(
    select 1 from public.assignments a
    join public.courses c on c.id = a.course_id
    where a.id = submissions.assignment_id and c.teacher_id = auth.uid()
  )
);

-- QUIZZES
drop policy if exists quizzes_select_by_course_access on public.quizzes;
create policy quizzes_select_by_course_access on public.quizzes
for select using (
  public.current_user_role() = 'admin'
  or exists(select 1 from public.courses c where c.id = quizzes.course_id and (c.teacher_id = auth.uid()))
  or exists(select 1 from public.enrollments e where e.course_id = quizzes.course_id and e.user_id = auth.uid())
);

drop policy if exists quizzes_write_by_teacher_admin on public.quizzes;
create policy quizzes_write_by_teacher_admin on public.quizzes
for insert with check (
  public.current_user_role() in ('teacher','admin')
);
create policy quizzes_update_by_teacher_admin on public.quizzes
for update using (
  public.current_user_role() = 'admin'
  or exists(select 1 from public.courses c where c.id = quizzes.course_id and c.teacher_id = auth.uid())
);

-- QUIZ QUESTIONS
drop policy if exists quiz_questions_select_by_course_access on public.quiz_questions;
create policy quiz_questions_select_by_course_access on public.quiz_questions
for select using (
  public.current_user_role() = 'admin'
  or exists(
    select 1 from public.quizzes q
    join public.courses c on c.id = q.course_id
    where q.id = quiz_questions.quiz_id and (c.teacher_id = auth.uid()
      or exists(select 1 from public.enrollments e where e.course_id = c.id and e.user_id = auth.uid()))
  )
);

drop policy if exists quiz_questions_write_by_teacher_admin on public.quiz_questions;
create policy quiz_questions_write_by_teacher_admin on public.quiz_questions
for insert with check (
  public.current_user_role() in ('teacher','admin')
);
create policy quiz_questions_update_by_teacher_admin on public.quiz_questions
for update using (
  public.current_user_role() = 'admin'
  or exists(
    select 1 from public.quizzes q
    join public.courses c on c.id = q.course_id
    where q.id = quiz_questions.quiz_id and c.teacher_id = auth.uid()
  )
);

-- QUIZ ATTEMPTS
drop policy if exists quiz_attempts_select_student_or_teacher on public.quiz_attempts;
create policy quiz_attempts_select_student_or_teacher on public.quiz_attempts
for select using (
  public.current_user_role() = 'admin'
  or student_id = auth.uid()
  or exists(
    select 1 from public.quizzes q
    join public.courses c on c.id = q.course_id
    where q.id = quiz_attempts.quiz_id and c.teacher_id = auth.uid()
  )
);

drop policy if exists quiz_attempts_insert_by_student on public.quiz_attempts;
create policy quiz_attempts_insert_by_student on public.quiz_attempts
for insert with check (
  student_id = auth.uid()
  and exists(
    select 1 from public.quizzes q
    join public.enrollments e on e.course_id = q.course_id and e.user_id = auth.uid()
    where q.id = quiz_attempts.quiz_id
  )
);

drop policy if exists quiz_attempts_update_by_owner_teacher on public.quiz_attempts;
create policy quiz_attempts_update_by_owner_teacher on public.quiz_attempts
for update using (
  public.current_user_role() = 'admin'
  or student_id = auth.uid()
  or exists(
    select 1 from public.quizzes q
    join public.courses c on c.id = q.course_id
    where q.id = quiz_attempts.quiz_id and c.teacher_id = auth.uid()
  )
);

-- CHAT MESSAGES (Realtime-enabled via UI)
drop policy if exists chat_messages_select_by_course_access on public.chat_messages;
create policy chat_messages_select_by_course_access on public.chat_messages
for select using (
  public.current_user_role() = 'admin'
  or exists(select 1 from public.courses c where c.id = chat_messages.course_id and (c.teacher_id = auth.uid()))
  or exists(select 1 from public.enrollments e where e.course_id = chat_messages.course_id and e.user_id = auth.uid())
);

drop policy if exists chat_messages_insert_by_enrolled_or_teacher on public.chat_messages;
create policy chat_messages_insert_by_enrolled_or_teacher on public.chat_messages
for insert with check (
  public.current_user_role() in ('admin','teacher')
  or exists(select 1 from public.enrollments e where e.course_id = chat_messages.course_id and e.user_id = auth.uid())
);

-- ANNOUNCEMENTS (Realtime-enabled via UI)
drop policy if exists announcements_select_by_course_access on public.announcements;
create policy announcements_select_by_course_access on public.announcements
for select using (
  public.current_user_role() = 'admin'
  or exists(select 1 from public.courses c where c.id = announcements.course_id and (c.teacher_id = auth.uid()))
  or exists(select 1 from public.enrollments e where e.course_id = announcements.course_id and e.user_id = auth.uid())
);

drop policy if exists announcements_insert_by_teacher_admin on public.announcements;
create policy announcements_insert_by_teacher_admin on public.announcements
for insert with check (
  public.current_user_role() in ('teacher','admin')
  and exists(select 1 from public.courses c where c.id = announcements.course_id and (c.teacher_id = auth.uid() or public.current_user_role() = 'admin'))
);

-- =========================
-- Indexes for performance
-- =========================
create index if not exists idx_enrollments_user on public.enrollments(user_id);
create index if not exists idx_enrollments_course on public.enrollments(course_id);
create index if not exists idx_modules_course on public.modules(course_id);
create index if not exists idx_assignments_course on public.assignments(course_id);
create index if not exists idx_submissions_assignment on public.submissions(assignment_id);
create index if not exists idx_submissions_student on public.submissions(student_id);
create index if not exists idx_chat_course on public.chat_messages(course_id);
create index if not exists idx_announcements_course on public.announcements(course_id);

-- =========================
-- Realtime instructions (manual step)
-- =========================
-- In Supabase Dashboard > Realtime:
-- - Enable Realtime for 'chat_messages' and 'announcements' tables (INSERT and UPDATE).
-- - Optionally enable row-level replication.
-- This allows frontend to subscribe to course chat and announcements channels.
